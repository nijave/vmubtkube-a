# natpmpc -a <public port> <private port> <protocol> <lifetime> -g 10.2.0.1

import logging
import signal
import subprocess
import sys
import time

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger()

PROTO = ("tcp", "udp")
ROUTER = "10.2.0.1"
PORT_LIFETIME = 60
LOOP_TIME = 45

"""
port open
ip = subprocess.check_output(["curl", "-4s", "https://ifconfig.me"],text=True)
"is open" in requests.post("https://ports.yougetsignal.com/check-port.php", data={"remoteAddress": ip, "portNumber": "43965"}).text
"""


def start_rtorrent(port):
    return subprocess.Popen(
        ["rtorrent", "-p", f"{port}-{port}"],
        text=True,
        stdout=sys.stdout,
        stderr=sys.stderr,
    )


def map_port(retry=True):
    ports = set()
    for p in PROTO:
        try:
            result = subprocess.check_output(
                ["timeout", "10", "natpmpc", "-a", "1", "0", p, str(PORT_LIFETIME), "-g", ROUTER],
                text=True,
                stderr=subprocess.STDOUT,
            )
        except subprocess.CalledProcessError:
            continue
        for line in result.splitlines():
            if line.startswith("Mapped public port"):
                mapped_port = line.split()[3]
                logger.info("Got port %s/%s", mapped_port, p)
                ports.add(mapped_port)
                break
    if len(ports) != 1:
        logger.info("Got %s ports. Trying to unmap", ports)
        unmap_port()
    if retry and len(ports) != 1:
        logger.info("Retrying port mapping")
        return map_port(retry=False)

    if len(ports) == 1:
        return list(ports)[0]


def unmap_port():
    for p in PROTO:
        print(
            subprocess.check_output(
                ["timeout", "10", "natpmpc", "-a", "1", "0", p, "0", "-g", ROUTER],
                text=True,
                stderr=subprocess.STDOUT,
            )
        )


def signal_handler(sig, _):
    global rtorrent
    if rtorrent is not None:
        rtorrent.send_signal(sig)


signal.signal(signal.SIGHUP, signal_handler)
signal.signal(signal.SIGUSR1, signal_handler)
signal.signal(signal.SIGUSR2, signal_handler)
signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

last_port = 0
rtorrent = None
rtorrent_stopping = 0
logger.info("Starting rtorrent runner")
while True:
    if rtorrent_stopping > 0:
        rtorrent_stopping += 1

    # Timeout after 10 waits and kill
    if rtorrent_stopping >= 10:
        rtorrent.kill()

    logger.info("Attempting to map port")
    port = map_port()
    logger.info("Mapped port %s", port)

    if port is not None and port != last_port and rtorrent is not None:
        logger.info("Port has changed. Restarting rtorrent")
        rtorrent_stopping = 1
        rtorrent.terminate()

    if rtorrent is None or rtorrent.poll() is not None and port:
        rtorrent_stopping = 0
        rtorrent = start_rtorrent(port)

    last_port = port

    logger.info("Waiting %d until next loop", LOOP_TIME)
    time.sleep(LOOP_TIME)
