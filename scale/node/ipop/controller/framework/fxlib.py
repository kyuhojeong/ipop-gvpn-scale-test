﻿#!/usr/bin/env python

import argparse
import binascii
import datetime
import getpass
import hashlib
import json
import logging
import os
import random
import select
import signal
import socket
import struct
import sys
import time
import urllib2

from threading import Timer
import controller.framework.ipoplib as ipoplib

ipopVerMjr = "15";
ipopVerMnr = "11";
ipopVerRev = "0";
ipopVerRel = ipopVerMjr + "." + ipopVerMnr + "." + ipopVerRev

# Set default config values
CONFIG = {
    "CFx": {
        "ip4_mask": 24,
        "ip6_mask": 64,
        "subnet_mask": 32,
        "contr_port": 5801,
        "local_uid": "",
        "uid_size": 40,
        "tincan_logging": 1,
        "router_mode": False,
        "trim_enabled": False,
        "ipopVerRel" : ipopVerRel
    },
    "Logger": {
        "controller_logging": "ERROR"
    },
    "TincanListener": {
        "buf_size": 65507,
        "socket_read_wait_time": 15,
        "dependencies": ["Logger"]
    },
    "TincanSender": {
        "stun": ["stun.l.google.com:19302", "stun1.l.google.com:19302",
                 "stun2.l.google.com:19302", "stun3.l.google.com:19302",
                 "stun4.l.google.com:19302"],
        "turn": [],
        "ip6_prefix": "fd50:0dbc:41f2:4a3c",
        "switchmode": 0,
        "localhost": "127.0.0.1",
        "svpn_port": 5800,
        "localhost6": "::1",
        "dependencies": ["Logger"]
     },
    "LinkManager": {
        "dependencies": ["Logger"]
    }
}

def gen_ip6(uid, ip6=None):
    if ip6 is None:
        ip6 = CONFIG["TincanSender"]["ip6_prefix"]
    for i in range(0, 16, 4):
        ip6 += ":" + uid[i:i+4]
    return ip6

def gen_uid(ip4):
    return hashlib.sha1(ip4).hexdigest()[:CONFIG["CFx"]["uid_size"]]

def make_call(sock, payload=None, **params):
    if socket.has_ipv6:
        dest = (CONFIG["TincanSender"]["localhost6"],
                CONFIG["TincanSender"]["svpn_port"])
    else:
        dest = (CONFIG["TincanSender"]["localhost"],
                CONFIG["TincanSender"]["svpn_port"])
    if payload is None:
        return sock.sendto(ipoplib.ipop_ver + ipoplib.tincan_control + json.dumps(params), dest)
    else:
        return sock.sendto(ipoplib.ipop_ver + ipoplib.tincan_packet + payload, dest)

def do_set_logging(sock, logging):
    return make_call(sock, m="set_logging", logging=logging)

def do_set_translation(sock, translate):
    return make_call(sock, m="set_translation", translate=translate)

def do_set_switchmode(sock, switchmode):
    return make_call(sock, m="set_switchmode", switchmode=switchmode)

def do_set_cb_endpoint(sock, addr):
    return make_call(sock, m="set_cb_endpoint", ip=addr[0], port=addr[1])

def do_set_local_ip(sock, uid, ip4, ip6, ip4_mask, ip6_mask, subnet_mask,
                    switchmode):
    return make_call(sock, m="set_local_ip", uid=uid, ip4=ip4, ip6=ip6,
                     ip4_mask=ip4_mask, ip6_mask=ip6_mask,
                     subnet_mask=subnet_mask, switchmode=switchmode)

def do_register_service(sock, username, password, host):
    return make_call(sock, m="register_svc", username=username,
                     password=password, host=host)

def do_set_trimpolicy(sock, trim_enabled):
    return make_call(sock, m="set_trimpolicy", trim_enabled=trim_enabled)

def do_get_state(sock, peer_uid="", stats=True):
    return make_call(sock, m="get_state", uid=peer_uid, stats=stats)

def load_peer_ip_config(ip_config):
    with open(ip_config) as f:
        ip_cfg = json.load(f)

    for peer_ip in ip_cfg:
        uid = peer_ip["uid"]
        ip = peer_ip["ipv4"]
        IP_MAP[uid] = ip
        logging.debug("MAP %s -> %s" % (ip, uid))



# # When proces killed or keyboard interrupted exit_handler runs then exit
# def exit_handler(signum, frame):
#     logging.info("Terminating Controller")
#     if CONFIG["stat_report"]:
#         if server != None:
#             server.report()
#         else:
#             logging.debug("Controller socket is not created yet")
#     sys.exit(0)

# signal.signal(signal.SIGINT, exit_handler)
# AFAIK, there is no way to catch SIGKILL
# signal.signal(signal.SIGKILL, exit_handler)
# signal.signal(signal.SIGQUIT, exit_handler)
# signal.signal(signal.SIGTERM, exit_handler)
