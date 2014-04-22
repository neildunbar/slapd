#!/bin/bash

set -eu

status () {
  echo "---> ${@}" >&2
}

set -x
: LDAP_ROOTPASS=${LDAP_ROOTPASS}
: LDAP_DOMAIN=${LDAP_DOMAIN}
: LDAP_ORGANISATION=${LDAP_ORGANISATION}

oldbase='/etc/slapd-config/base.ldif'
newbase='/etc/slapd-config/newbase.ldif'
config='/etc/ldap/slapd.d/cn=config.ldif'
configdb='/etc/ldap/slapd.d/cn=config/olcDatabase={0}config.ldif'
maindb='/etc/ldap/slapd.d/cn=config/olcDatabase={1}mdb.ldif'

PATH=/opt/openldap/sbin:$PATH
export PATH

if [ -f /etc/ldap/ssl/openldap-cert.pem ]; then
    hostname=$(openssl x509 -in /etc/ldap/ssl/openldap-cert.pem -subject -noout | sed -e "s|subject *= */cn=||i")
else
    hostname=""
fi

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
  cp ${oldbase} ${newbase}
  for h in $(echo -n ${LDAP_CLUSTER} | tr ',' '\n'); do
     sid=$((${sid} + 1))
     h=$(echo -n ${h} | sed -e 's/^ *//' -e 's/ *$//') # trim whitespace
     echo "" >> ${newbase}
     echo "dn: cn=${h},ou=Applications,${enc_domain}" >> ${newbase}
     echo "objectClass: top" >> ${newbase}
     echo "objectClass: device" >> ${newbase}
     echo "cn: ${h}" >> ${newbase}
     echo "" >> ${newbase}
     ldapuri="ldap://${h}"
     echo "olcServerID: ${sid} ${ldapuri}" >> ${config}

     rid=$((${ridbase} + ${sid}))
     echo "olcSyncRepl: rid=$(printf %03d ${rid}) provider=${ldapuri} bindmethod=sasl " >> ${configdb}
     echo " retry=\"5 10 30 +\" searchbase=\"cn=config\" type=refreshAndPersist " >> ${configdb}
     echo " saslmech=external sizelimit=unlimited tls_reqcert=demand " >> ${configdb}

     echo " starttls=yes tls_cacert=/etc/ldap/ssl/ssl-ca.pem " >> ${configdb}
     echo " tls_cert=/etc/ldap/ssl/openldap-cert.pem " >> ${configdb}
     echo " tls_key=/etc/ldap/ssl/openldap-key.pem " >> ${configdb}
  done
  echo "olcMirrorMode: TRUE" >> ${configdb}

  ridbase=${sid}
  for h in $(echo -n ${LDAP_CLUSTER} | tr ',' '\n'); do
     sid=$((${sid} + 1))
     rid=$((${ridbase} + ${sid}))
     ldapuri="ldap://${h}"
     echo "olcSyncRepl: rid=$(printf %03d ${rid}) provider=${ldapuri} bindmethod=sasl " >> ${maindb}
     echo " retry=\"5 10 30 +\" searchbase=\"${enc_domain}\" type=refreshAndPersist " >> ${maindb}
     echo " saslmech=external sizelimit=unlimited tls_reqcert=demand " >> ${maindb}

     echo " starttls=yes tls_cacert=/etc/ldap/ssl/ssl-ca.pem " >> ${maindb}
     echo " tls_cert=/etc/ldap/ssl/openldap-cert.pem " >> ${maindb}
     echo " tls_key=/etc/ldap/ssl/openldap-key.pem " >> ${maindb}
  done
  echo "olcMirrorMode: TRUE" >> ${maindb}

  if [ -n ${LDAP_CLUSTER} ]; then
      echo "dn: cn=ldap-replicators,ou=Groups,${enc_domain}" >> ${newbase}
      echo "objectClass: top" >> ${newbase}
      echo "objectClass: groupOfNames" >> ${newbase}
      echo "cn: ldap-replicators" >> ${newbase}
      echo "description: Clients capable of replicating DIT" >> ${newbase}
      for h in $(echo -n ${LDAP_CLUSTER} | tr ',' '\n'); do
	  echo "member: cn=${h},ou=Applications,${enc_domain}" >> ${newbase}
      done
      echo "" >> ${newbase}
  fi

  # export, then reimport the LDIF
  /opt/openldap/sbin/slapcat -b "cn=config" -F /etc/ldap/slapd.d -l /var/lib/ldap/config.ldif -c
  find /etc/ldap/slapd.d -name \*\=\*.ldif -exec rm {} \;
  /opt/openldap/sbin/slapadd -b "cn=config" -c -F /etc/ldap/slapd.d -l /var/lib/ldap/config.ldif
  rm -f /var/lib/ldap/config.ldif
  echo "slapadd begins"
  /opt/openldap/sbin/slapadd -b ${enc_domain} -c -F /etc/ldap/slapd.d -l ${newbase} -w
  echo "slapadd complete"
  chown -R openldap:openldap /var/lib/ldap
  touch /var/lib/ldap/docker_bootstrapped
  echo "configured slapd"
else
  status "found already-configured slapd"
fi

status "configuring dnsmasq"
echo "nameserver 8.8.8.8" > /etc/resolv.dnsmasq.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.dnsmasq.conf

echo "listen-address=127.0.0.1" > /etc/dnsmasq.conf
echo "resolv-file=/etc/resolv.dnsmasq.conf" >> /etc/dnsmasq.conf
echo "conf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf
echo "user=root" >> /etc/dnsmasq.conf

echo "address=\"/${hostname}/127.0.0.1\"" >> /etc/dnsmasq.d/0hosts
service dnsmasq start

status "starting slapd"
# set -x
mkdir -m 0700 -p /var/run/slapd
chown -R openldap:openldap /var/run/slapd /etc/ldap
exec /opt/openldap/lib/slapd -h "ldap://${hostname} ldap://$(hostname) ldaps:///" -u openldap -g openldap -d 0

