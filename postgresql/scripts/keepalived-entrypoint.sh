#!/bin/bash
set -e

# Generate keepalived.conf from environment variables
mkdir -p /etc/keepalived
cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_instance VI_PG {
    state ${KEEPALIVED_STATE}
    interface ${KEEPALIVED_INTERFACE}
    virtual_router_id 51
    priority ${KEEPALIVED_PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_PASSWORD}
    }
    virtual_ipaddress {
        172.16.0.200/24
    }
}
EOF

exec keepalived --dont-fork --log-console
