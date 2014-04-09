#!/bin/sh

set -eu

status () {
  echo "---> ${@}" >&2
}

set -x
: LDAP_ROOTPASS=${LDAP_ROOTPASS}
: LDAP_DOMAIN=${LDAP_DOMAIN}
: LDAP_ORGANISATION=${LDAP_ORGANISATION}

if [ ! -e /var/lib/ldap/docker_bootstrapped ]; then
  status "configuring slapd for first run"
  rm -rf /etc/ldap/slapd.d/*
  mkdir -p /etc/ldap/ssl
  (cd /etc/slapd-config ; tar cpf - .) | (cd /etc/ldap/slapd.d ; tar xpf - )
  chown -R openldap:openldap /etc/ldap
  [ -f /etc/ldap/ssl/openldap-key.pem ] && chmod 600 /etc/ldap/ssl/openldap-key.pem
  [ -f /etc/ldap/ssl/dhparam.pem ] || openssl dhparam -out /etc/ldap/ssl/dhparam.pem 2048
  enc_pw=$(slappasswd -h '{SSHA}' -s ${LDAP_ROOTPASS} | base64)
  enc_domain=$(echo -n ${LDAP_DOMAIN} | sed -e "s|^|dc=|" -e "s|\.|,dc=|g")
  dc_one=$(echo -n ${enc_domain} | sed -e "s|^dc=||" -e "s|,dc=.*$||g")

  for f in $(find /etc/slapd-config -name \*.ldif) $(find /etc/ldap/slapd.d -name \*.ldif); do
     sed -i \
        -e "s|___sub_root_passwd_here___|${enc_pw}|g" \
        -e "s|___sub_organization_here___|${LDAP_ORGANISATION}|g" \
        -e "s|___sub_dcone_here___|${dc_one}|g" \
        -e "s|___sub_domain_here___|${enc_domain}|g" \
        $f
  done
  slapadd -b ${enc_domain} -c -F /etc/ldap/slapd.d -l /etc/slapd-config/base.ldif
  chown -R openldap:openldap /var/lib/ldap
  touch /var/lib/ldap/docker_bootstrapped
else
  status "found already-configured slapd"
fi

status "starting slapd"
set -x
exec /usr/sbin/slapd -h "ldap:/// ldaps:/// ldapi:///" -u openldap -g openldap -d 0
