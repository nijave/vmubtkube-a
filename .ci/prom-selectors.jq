# Input: array of k8s objects (instances, selectable CRs, Namespaces).
# Output: one line per selectable CR that no instance selects.
# Operator semantics: nil resource selector = select nothing; {} = everything.
# nil namespace selector = instance's own namespace only; {} = all namespaces.

def matches_selector($sel; $labels):
  if $sel == null then false
  else
    (($sel.matchLabels // {}) | to_entries | all(. as $e | $labels[$e.key] == $e.value))
    and
    (($sel.matchExpressions // []) | all(
      . as $x |
      if   $x.operator == "In"           then ($labels | has($x.key)) and ($x.values | index($labels[$x.key])) != null
      elif $x.operator == "NotIn"        then (($labels | has($x.key)) and ($x.values | index($labels[$x.key])) != null) | not
      elif $x.operator == "Exists"       then $labels | has($x.key)
      elif $x.operator == "DoesNotExist" then $labels | has($x.key) | not
      else false end))
  end;

def ns_labels($all; $ns):
  ([$all[] | select(.kind == "Namespace" and .metadata.name == $ns) | .metadata.labels // {}] | first // {})
  + {"kubernetes.io/metadata.name": $ns};

def ns_matches($all; $inst; $nsSel; $ns):
  if $nsSel == null then $inst.metadata.namespace == $ns
  else matches_selector($nsSel; ns_labels($all; $ns)) end;

# kind -> [instance kind, resource selector field, namespace selector field]
def wiring: {
  "ServiceMonitor":     [["Prometheus","serviceMonitorSelector","serviceMonitorNamespaceSelector"],
                         ["PrometheusAgent","serviceMonitorSelector","serviceMonitorNamespaceSelector"]],
  "PodMonitor":         [["Prometheus","podMonitorSelector","podMonitorNamespaceSelector"],
                         ["PrometheusAgent","podMonitorSelector","podMonitorNamespaceSelector"]],
  "Probe":              [["Prometheus","probeSelector","probeNamespaceSelector"],
                         ["PrometheusAgent","probeSelector","probeNamespaceSelector"]],
  "ScrapeConfig":       [["Prometheus","scrapeConfigSelector","scrapeConfigNamespaceSelector"],
                         ["PrometheusAgent","scrapeConfigSelector","scrapeConfigNamespaceSelector"]],
  "PrometheusRule":     [["Prometheus","ruleSelector","ruleNamespaceSelector"],
                         ["ThanosRuler","ruleSelector","ruleNamespaceSelector"]],
  "AlertmanagerConfig": [["Alertmanager","alertmanagerConfigSelector","alertmanagerConfigNamespaceSelector"]]
};

. as $all
| wiring as $w
| $all[]
| select(.apiVersion | startswith("monitoring.coreos.com/"))
| select($w[.kind])
| . as $obj
| ($obj.metadata.labels // {}) as $labels
| select(
    [ $w[$obj.kind][] as [$ik, $sf, $nf]
      | $all[] | select(.kind == $ik and (.apiVersion | startswith("monitoring.coreos.com/")))
      | . as $inst
      | select(matches_selector($inst.spec[$sf]; $labels)
               and ns_matches($all; $inst; $inst.spec[$nf]; $obj.metadata.namespace))
    ] | length == 0)
| "\($obj.kind) \($obj.metadata.namespace)/\($obj.metadata.name) labels=\($labels | tojson)"
