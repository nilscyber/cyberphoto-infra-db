#!/bin/bash
set -e

# Generate patroni.yml from template with environment variable substitution
envsubst < /etc/patroni/patroni.yml.tmpl > /tmp/patroni.yml

exec patroni /tmp/patroni.yml
