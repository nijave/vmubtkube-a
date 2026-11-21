#!/usr/bin/env bash
# ssa-stray-owners.sh - find Argo CD-tracked objects whose managedFields show
# field owners other than Argo (stray owners).
#
# usage: ./ssa-stray-owners.sh [--file <path>]... [--all-objects] [--all-managers]
#                              [--uncovered-only] [--include-defaults]
#        PAR=8 SUSPECT_RE='^(kubectl.*|helm|argocd)$' DEFAULTS_RE=... ./ssa-stray-owners.sh
# needs: bash, kubectl (read-only: api-resources + get), jq
#
# Why: every Argo app here syncs with ServerSideApply=true. With server-side
# apply, when a key is removed from git, Argo releases only its own ownership.
# If another manager (kubectl-create/replace/edit/patch, a pre-Argo helm
# install, ...) also owns that field, the field stays live forever. That
# caused a real outage: stale Helm values stayed on an Application and broke
# chart rendering.
#
# For every object carrying the `argocd.argoproj.io/tracking-id` annotation,
# each non-Argo managedFields entry (subresource=status skipped) is flattened
# to leaf paths (top-level f:status dropped) and compared against the union of
# all Argo managers' leaf paths on the same object. A leaf is COVERED when an
# Argo manager owns the same path, an ancestor, or a descendant (compared by
# segment arrays, so `.foo` never matches `.foobar`); otherwise UNCOVERED,
# meaning git does not set that field: it is stuck now, or was added by hand.
#
# Output: TSV to stdout, header first:
#   STATE CLASS APP KIND NAMESPACE NAME MANAGER OPERATION TIME PATH
# Default shows SUSPECT managers only; --all-managers also shows CONTROLLER.
# --uncovered-only keeps only UNCOVERED rows. UNCOVERED rows sort first.
# Fields the API server or a CRD schema defaults, Helm release bookkeeping and
# one-shot trigger annotations are hidden (see DEFAULTS_RE_BUILTIN);
# --include-defaults shows them. An object counts as Argo-tracked only when
# its tracking-id names the object itself, not a parent CR it was copied from.
# Summary goes to stderr.
#
# --file reads saved `kubectl get -o json` List documents instead of the
# cluster (for testing); repeatable. Cluster mode enumerates listable
# resources and fetches them in parallel (PAR workers); a resource that errors
# (aggregated APIs often do) is warned about on stderr and skipped.
# This script never writes to the cluster.

set -uo pipefail

PAR=${PAR:-8}
[[ $PAR =~ ^[0-9]+$ ]] || PAR=8
SUSPECT_RE=${SUSPECT_RE:-'^(kubectl.*|helm|argocd)$'}
FILES=()
ALL_OBJECTS=false
ALL_MANAGERS=false
UNCOVERED_ONLY=false
INCLUDE_DEFAULTS=false

# Harmless rows hidden unless --include-defaults. Matched (jq/Oniguruma regex)
# against "<Kind> <path>". A manager that creates an object is credited with
# every field the API server or CRD schema defaults, though Argo never sends
# them; such a field cannot get stuck in a harmful way. Also hidden: Helm
# release bookkeeping and one-shot trigger annotations.
DEFAULTS_RE_BUILTIN=$(tr -d ' \n' <<'EOF'
\.terminationMessage(Path|Policy)$
|\.(imagePullPolicy|resources)$
|Probe\.(successThreshold|failureThreshold|timeoutSeconds|periodSeconds|httpGet\.scheme)$
|\.ports\[[^]]*\]\.protocol$
|\.(configMap|secret|projected)\.defaultMode$
|\.hostPath\.type$
|\.spec\.template\.spec\.(schedulerName|restartPolicy|dnsPolicy|terminationGracePeriodSeconds|securityContext|serviceAccount)$
|^(Deployment|StatefulSet|DaemonSet)\s\.spec\.(progressDeadlineSeconds|revisionHistoryLimit|podManagementPolicy)$
|^(Deployment|StatefulSet|DaemonSet)\s\.spec\.(strategy|updateStrategy|persistentVolumeClaimRetentionPolicy)\.
|\.volumeMode$
|^Service\s\.spec\.(sessionAffinity|internalTrafficPolicy|ipFamilies|ipFamilyPolicy|clusterIP|clusterIPs|type)$
|^Service\s\.spec\.ports\[[^]]*\]\.targetPort$
|^(Mutating|Validating)WebhookConfiguration\s\.webhooks\[[^]]*\]\.(sideEffects|timeoutSeconds|matchPolicy|namespaceSelector|objectSelector|reinvocationPolicy|admissionReviewVersions|failurePolicy|rules\[.*\]\.scope|clientConfig\.service\.port)$
|^CSIDriver\s\.spec\.(fsGroupPolicy|requiresRepublish|seLinuxMount|storageCapacity|volumeLifecycleModes)
|^ExternalSecret\s\.spec\.target\.(creationPolicy|deletionPolicy|template\.(engineVersion|mergePolicy))$
|^SecretStore\s\.spec\.provider\.kubernetes\.server\.url$
|^Cluster\s\.spec\.(failoverDelay|logLevel|maxSyncReplicas|minSyncReplicas|postgresGID|postgresUID|primaryUpdateMethod|replicationSlots\.|smartShutdownTimeout|storage\.resizeInUseVolumes|switchoverDelay)
|^Database\s\.spec\.(databaseReclaimPolicy|ensure)$
|^Prometheus\s\.spec\.evaluationInterval$
|^Secret\s\.type$
|\.metadata\.annotations\["checksum/[^"]*"\]$
|\.metadata\.annotations\["(meta\.helm\.sh/release-(name|namespace)|deprecated\.daemonset\.template\.generation|kubectl\.kubernetes\.io/restartedAt)"\]$
|\.metadata\.annotations\.(force-sync|force-reconcile)$
|\.metadata\.labels\["(app\.kubernetes\.io/managed-by|kubernetes\.io/metadata\.name)"\]$
EOF
)
DEFAULTS_RE=${DEFAULTS_RE:-$DEFAULTS_RE_BUILTIN}

usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --file) [[ $# -ge 2 ]] || { echo "--file needs a path" >&2; exit 2; }
            FILES+=("$2"); shift 2 ;;
    --all-objects) ALL_OBJECTS=true; shift ;;
    --all-managers) ALL_MANAGERS=true; shift ;;
    --uncovered-only) UNCOVERED_ONLY=true; shift ;;
    --include-defaults) INCLUDE_DEFAULTS=true; shift ;;
    *) echo "unknown argument: $1 (see -h)" >&2; exit 2 ;;
  esac
done

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT
objs=$tmpd/objects.jsonl

export SUSPECT_RE ALL_OBJECTS ALL_MANAGERS UNCOVERED_ONLY

# ---------------------------------------------------------------- collect

if [[ ${#FILES[@]} -gt 0 ]]; then
  for f in "${FILES[@]}"; do
    jq -ce 'if (type == "object") and (.items? | type == "array")
            then .items[] else . end' "$f" >>"$objs" \
      || echo "warning: could not read $f as a kubectl List document" >&2
  done
else
  collect() {   # one resource -> jsonl of its objects, or a one-line warning
    local res=$1 dir=$2 f
    f=$dir/res/"$(printf %s "$res" | tr '/.' '__').jsonl"
    # pipefail makes a kubectl failure fail the pipeline; jq tolerates both
    # empty input (empty list is a valid answer) and .items being absent.
    if kubectl get "$res" -A -o json --show-managed-fields 2>/dev/null \
        | jq -c '.items[]?' >"$f"; then
      [[ -s $f ]] || rm -f "$f"
    else
      echo "warning: skipping resource '$res' (query failed; aggregated API?)" >&2
      rm -f "$f"
    fi
  }
  export -f collect

  kubectl api-resources --verbs=list -o name 2>/dev/null \
    | grep -v -e '^events$' -e '^events.events.k8s.io$' -e '^$' \
    | sort -u >"$tmpd/resources"
  mkdir -p "$tmpd/res"
  xargs -a "$tmpd/resources" -P "$PAR" -I{} bash -c 'collect "$@"' _ {} "$tmpd"
  cat "$tmpd"/res/*.jsonl >>"$objs" 2>/dev/null
fi

# ---------------------------------------------------------------- analyze

# jq: flatten a fieldsV1 tree to leaf-path segment arrays.
#   f:<name>  -> field; a name containing "." or "/" becomes ["name"] (json-quoted)
#   k:<json>  -> associative-list item: [<k>=<v>,...]
#   v:<json>  -> set-list item:         [=v]
#   "." marks ownership of the containing node itself: a node whose only key is
#   "." is a leaf; otherwise "." is ignored (its children are the leaves).
#   {} is a leaf.
read -r -d '' JQ_FLATTEN <<'EOF' || true
def segname: if test("[./]") then "[" + tojson + "]" else . end;
def flatten($p):
  if (type == "object") and (length > 0) and (keys != ["."]) then
    [ to_entries[]
      | if .key == "." then empty
        elif (.key | startswith("f:")) then
          (.key[2:] | segname) as $s | (.value | flatten($p + [$s]))
        elif (.key | startswith("k:")) then
          (.key[2:] | fromjson) as $kv
          | ([ $kv | to_entries[] | "\(.key)=\(.value | tostring)" ] | join(",")) as $s
          | (.value | flatten($p + [ "[" + $s + "]" ]))
        elif (.key | startswith("v:")) then
          (.key[2:] | fromjson | tojson) as $s
          | (.value | flatten($p + [ "[=" + $s + "]" ]))
        else empty end ]
    | add // []
  else [$p] end;
EOF

# jq: per object -> {"t":"stat"} or a full record (only when stray managers exist)
read -r -d '' JQ_PEROBJ <<'EOF' || true
include_flatten_placeholder
. as $o
| ($o.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") as $tid
| select($all_objects == "true" or $tid != "")
| ($o.kind // "?") as $kind
| ($o.metadata.namespace // "-") as $ns
| ($o.metadata.name // "?") as $nm
# Argo honours a tracking-id only when it names this object; operators often
# copy their CR's annotations onto children (e.g. PVCs), which Argo ignores.
# Cluster-scoped objects often carry the app namespace in the id (Helm charts
# render one); Argo ignores the namespace for them, so compare without it.
| (($o.apiVersion // "") | if contains("/") then split("/")[0] else "" end) as $grp
| ($tid | split(":")[1:] | join(":")) as $tref
| (if $o.metadata.namespace then $tref
   else ($tref | sub(":[^:/]*/"; ":/")) end) as $tref
| select($all_objects == "true"
         or $tref == "\($grp)/\($kind):\($o.metadata.namespace // "")/\($nm)")
| (if $tid == "" then "-" else ($tid | split(":")[0]) end) as $app
| ([ $o.metadata.managedFields[]?
     | select(.fieldsV1 != null and (.subresource // "") != "status")
     | if .manager == "argocd-controller"
          or .manager == "argocd-application-controller"
          or .manager == "argocd-server" then
         {argo: (.fieldsV1 | flatten([]) | map(select(.[0] != "status")))}
       else
         {other: {m: .manager, op: (.operation // "-"), tm: (.time // "-"),
                  paths: (.fieldsV1 | flatten([]) | map(select(.[0] != "status")))}}
       end ])
  as $ents
| ([ $ents[] | .argo // empty ] | add // []) as $argo
| [ $ents[] | .other // empty ] as $others
| if ($others | length) == 0 then {"t": "stat"}
  else {"t": "full", k: $kind, ns: $ns, nm: $nm, app: $app, a: $argo, o: $others}
  end
EOF

# jq: full records -> filtered+sorted TSV rows
read -r -d '' JQ_ROWS <<'EOF' || true
def ispre($a; $b): ($a | length) <= ($b | length) and $a == $b[0:($a | length)];
def rend: if length == 0 then "."
          else map(if startswith("[") then . else "." + . end) | join("") end;
[ .[] | select(.t == "full")
  | . as $r
  | $r.o[]
  | . as $e
  | $e.paths[]
  | . as $p
  | (any($r.a[]; ispre(.; $p) or ispre($p; .))) as $cov
  # serviceAccountName is mirrored by the API server from the deprecated
  # serviceAccount field that many charts still render
  | ($p[-1] == "serviceAccountName"
     and any($r.a[]; . == ($p[0:-1] + ["serviceAccount"]))) as $mirrored
  | select($include_defaults == "true"
           or ($mirrored | not)
              and (("\($r.k) " + ($p | rend)) | test($defaults_re) | not))
  | {state: (if $cov then "COVERED" else "UNCOVERED" end),
     class: (if ($e.m | test($suspect_re)) then "SUSPECT" else "CONTROLLER" end),
     app: $r.app, kind: $r.k, ns: $r.ns, nm: $r.nm,
     m: $e.m, op: $e.op, tm: $e.tm, path: ($p | rend)} ]
| (if $uncovered_only == "true" then map(select(.state == "UNCOVERED")) else . end)
| (if $all_managers == "true" then . else map(select(.class == "SUSPECT")) end)
| sort_by([.state != "UNCOVERED", .app, .kind, .nm, .m, .path])
| "STATE\tCLASS\tAPP\tKIND\tNAMESPACE\tNAME\tMANAGER\tOPERATION\tTIME\tPATH",
  ( .[] | [.state, .class, .app, .kind, .ns, .nm, .m, .op, .tm, .path] | @tsv )
EOF

perobj=${JQ_PEROBJ/include_flatten_placeholder/$JQ_FLATTEN}

jq -c --arg all_objects "$ALL_OBJECTS" "$perobj" "$objs" >"$tmpd/records"
jq -r -s --arg all_managers "$ALL_MANAGERS" --arg uncovered_only "$UNCOVERED_ONLY" \
  --arg suspect_re "$SUSPECT_RE" --arg include_defaults "$INCLUDE_DEFAULTS" \
  --arg defaults_re "$DEFAULTS_RE" "$JQ_ROWS" "$tmpd/records" >"$tmpd/rows"

cat "$tmpd/rows"

# ---------------------------------------------------------------- summary

n_scan=$(wc -l <"$tmpd/records")
n_stray=$(jq -s '[.[] | select(.t == "full")] | length' "$tmpd/records")
echo "summary: objects scanned=$n_scan, objects with stray managers=$n_stray" >&2
tail -n +2 "$tmpd/rows" | awk -F'\t' '
  BEGIN { split("UNCOVERED/SUSPECT UNCOVERED/CONTROLLER COVERED/SUSPECT COVERED/CONTROLLER", ord, " ") }
  { c[$1 "/" $2]++ }
  END {
    for (i = 1; i <= 4; i++)
      if (ord[i] in c) printf "summary: rows %s=%d\n", ord[i], c[ord[i]]
  }' >&2
