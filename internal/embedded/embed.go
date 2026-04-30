package embedded

import (
	_ "embed"
)

//go:embed unbound.conf
var UnboundConf string

//go:embed kea-dhcp4.conf.template
var KeaTemplate string

//go:embed dns-healthcheck.sh
var HealthCheckScript string
