#!/bin/bash

set -eu

status () {
  echo "---> ${@}" >&2
}

set -x
: LDAP_ROOTPASS=${LDAP_ROOTPASS}
: LDAP_DOMAIN=${LDAP_DOMAIN}
: LDAP_ORGANISATION=${LDAP_ORGANISATION}

base='/etc/slapd-config/base.ldif'
config='/etc/ldap/slapd.d/cn=config.ldif'
configdb='/etc/ldap/slapd.d/cn=config/olcDatabase={0}config.ldif'

PATH=/opt/openldap/sbin:$PATH
export PATH

if [ ! -e /var/lib/ldap/docker_bootstrapped ]; then
  status "configuring slapd for first run"
  rm -rf /etc/ldap/slapd.d/*
  mkdir -p /etc/ldap/ssl
  (cd /etc/slapd-config ; tar cpf - .) | (cd /etc/ldap/slapd.d ; tar xpf - )
  chown -R openldap:openldap /etc/ldap
  [ -f /etc/ldap/ssl/openldap-key.pem ] && chmod 600 /etc/ldap/ssl/openldap-key.pem
  [ -f /etc/ldap/ssl/dhparam.pem ] || openssl dhparam -out /etc/ldap/ssl/dhparam.pem 2048
  if [ -f /etc/ldap/ssl/openldap-cert.pem ]; then
      hostname=$(openssl x509 -in /etc/ldap/ssl/openldap-cert.pem -subject -noout | sed -e "s|subject *= */cn=||i")
  else
      hostname=""
  fi
  enc_pw=$(slappasswd -h '{SSHA}' -s ${LDAP_ROOTPASS} | base64)
  enc_domain=$(echo -n ${LDAP_DOMAIN} | sed -e "s|^|dc=|" -e "s|\.|,dc=|g")
  dc_one=$(echo -n ${enc_domain} | sed -e "s|^dc=||" -e "s|,dc=.*$||g")

  for f in $(find /etc/slapd-config -name \*.ldif) $(find /etc/ldap/slapd.d -name \*.ldif); do
     echo "Processing file ${f}"
     sed -i \
        -e "s|___sub_root_passwd_here___|${enc_pw}|g" \
        -e "s|___sub_organization_here___|${LDAP_ORGANISATION}|g" \
        -e "s|___sub_dcone_here___|${dc_one}|g" \
	-e "s|___sub_raw_domain_here___|${LDAP_DOMAIN}|g" \
        -e "s|___sub_domain_here___|${enc_domain}|g" \
        $f
  done

  # for each member of the cluster (if any), add an identity entry into base.ldif
  sid=0
  ridbase=0
  for h in $(echo -n ${LDAP_CLUSTER} | tr ',' '\n'); do
     sid=$((${sid} + 1))
     h=$(echo -n ${h} | sed -e 's/^ *//' -e 's/ *$//') # trim whitespace
     echo "" >> ${base}
     echo "dn: cn=${h},ou=Applications,${enc_domain}" >> ${base}
     echo "objectClass: top" >> ${base}
     echo "objectClass: device" >> ${base}
     echo "cn: ${h}" >> ${base}
     echo "" >> ${base}
     if [ "${h,,}" = "${hostname,,}" ]; then
        echo "olcServerID: ${sid}" >> ${config}
     fi

     rid=$((${ridbase} + ${sid}))
     echo "olcSyncRepl: rid=$(printf %03d ${rid}) provider=ldap://${h} bindmethod=sasl " >> ${configdb}
     echo " retry=\"5 10 30 +\" searchbase=\"cn=config\" type=refreshAndPersist " >> ${configdb}
     echo " saslmech=external sizelimit=unlimited tls_reqcert=demand " >> ${configdb}

     echo " starttls=yes tls_cacert=/etc/ldap/ssl/ssl-ca.pem " >> ${configdb}
     echo " tls_cert=/etc/ldap/ssl/openldap-cert.pem " >> ${configdb}
     echo " tls_key=/etc/ldap/ssl/openldap-key.pem " >> ${configdb}
  done
  echo "olcMirrorMode: TRUE" >> ${configdb}

  if [ -n ${LDAP_CLUSTER} ]; then
      echo "dn: cn=ldap-replicators,ou=Groups,${enc_domain}" >> ${base}
      echo "objectClass: top" >> ${base}
      echo "objectClass: groupOfNames" >> ${base}
      echo "cn: ldap-replicators" >> ${base}
      echo "description: Clients capable of replicating DIT" >> ${base}
      for h in $(echo -n ${LDAP_CLUSTER} | tr ',' '\n'); do
	  echo "member: cn=${h},ou=Applications,${enc_domain}" >> ${base}
      done
      echo "" >> ${base}
  fi

  slapadd -b ${enc_domain} -c -F /etc/ldap/slapd.d -l ${base} -w
  chown -R openldap:openldap /var/lib/ldap
  touch /var/lib/ldap/docker_bootstrapped
else
  status "found already-configured slapd"
fi

status "starting slapd"
set -x
mkdir -m 0700 -p /var/run/slapd
chown -R openldap:openldap /var/run/slapd
exec /opt/openldap/lib/slapd -h "ldap:/// ldaps:/// ldapi:///" -u openldap -g openldap -d 0
