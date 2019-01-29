#!/bin/bash

package_path=$1
autosign_token=$2

if [ -z "$autosign_token" ] ; then
  echo "usage: $0 package_path autosign_token" >&2
  exit 1
fi

set -ex
set -o pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

if command -v apt-get >/dev/null ; then
  apt-get update
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Dpkg::Options::="--force-confnew" --assume-yes dist-upgrade
  apt-get -o Dpkg::Options::="--force-confnew" --assume-yes install curl lsb-release
elif command -v yum >/dev/null ; then
  yum -y update
fi

# 169.254.169.254 is the AWS EC2 metadata service
cloud_id=$(curl -sS http://169.254.169.254/latest/meta-data/instance-id | tr -d -)
certname="$(hostname -s)-${cloud_id}.certs.puppet.net"

# Install Puppet, but don't run it
curl -sSk https://puppet.ops.puppetlabs.net:8140/packages/current/install.bash \
  | bash -s -- \
    "agent:certname=$certname" \
    --puppet-service-ensure stopped \
    --puppet-service-enable false

cat <<EOF >$(puppet config --section main print confdir)/csr_attributes.yaml
custom_attributes:
  challengePassword: "${autosign_token}"
extension_requests:
  pp_network: "$(hostname -d)"
  pp_cloudplatform: aws
  pp_instance_id: "$(curl -sS http://169.254.169.254/latest/meta-data/instance-id)"
  pp_zone: "$(curl -sS http://169.254.169.254/latest/meta-data/placement/availability-zone)"
  pp_region: "$(curl -sS http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/.$//')"
EOF

# Run Puppet twice to ensure it coallesces
puppet agent --test --waitforcert 5 --server puppet.ops.puppetlabs.net || true
# There is some sort of race condition that sometimes causes the second run
# to fail.
sleep 5
puppet agent --test || true

# Validate that the server works
if ! ls -1 /home | fgrep -qvxe admin -e centos ; then
  echo "No users other than admin and centos in /home"
  exit 1
fi

puppet resource service puppet ensure=stopped enable=false

cat >/etc/motd <<EOF
               __
              / _) - Hello.
     _.----._/ /     I'm still booting.
    /         /
 __/ (  | (  |
/__.-'|_|--|_|

AMI generated $(date '+%Y-%m-%d %H:%M:%S %Z')

EOF

# Remove puppet agent cron job, along with all others
crontab -r

# Strip old cert and autosign token
rm -f "$(puppet config --section main print confdir)/csr_attributes.yaml"
rm -rf "$(puppet config --section main print ssldir)"
puppet config --section main delete certname

# /etc/hosts will be generated by instance-first-boot.sh
echo "manage_etc_hosts: false" >/etc/cloud/cloud.cfg.d/50_puppet.cfg
cp "${package_path}/instance-first-boot.sh" /var/lib/cloud/scripts/per-once/

rm -rf "$package_path"

rm /opt/puppetlabs/facter/facts.d/profile_metadata.yaml

# Reset cloud-init
rm -rf /var/lib/cloud/instances/*
rm -f /var/lib/cloud/instance
rm -rf /var/lib/cloud/sem/*
cp /dev/null /var/log/cloud-init.log
cp /dev/null /var/log/cloud-init-output.log
