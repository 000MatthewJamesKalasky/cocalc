#!/usr/bin/env python

import time, util

while True:
    try:
        print "Visit       https://cloud.sagemath.com" + util.base_url() + '/\n'
    except:
        print "waiting..."
    time.sleep(15)

