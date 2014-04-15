## slapd

A basic configuration of the OpenLDAP server, slapd, with support for data
volumes. This code is based on Nick Stenning's simple slapd container,
with added support for TLS (and multi-master clustering, eventually).

This image will initialize a basic configuration of slapd. Most common
schemas are preloaded (all the schemas that come preloaded with the
default Ubuntu Precise install of slapd). In addition to the top level
dcObject, a set of ou's for common divisions (People, Groups,
Applications) is added in.

The default DB engine used is back_mdb.

You can (and should) configure the following by providing environment variables
to `docker run`:

- `LDAP_DOMAIN` sets the LDAP root domain. (e.g. if you provide `foo.bar.com`
  here, the root of your directory will be `dc=foo,dc=bar,dc=com`)
- `LDAP_ORGANISATION` sets the human-readable name for your organisation (e.g.
  `Acme Widgets Inc.`)
- `LDAP_ROOTPASS` sets the LDAP admin user password (i.e. the password for
  `cn=admin,dc=example,dc=com` if your domain was `example.com`)

The following directories can be mounted if you want to inject
configuration from the outside:

- `/var/lib/ldap` which is the store for the database
- `/etc/ldap/slapd.d` which is the store for the LDAP server configuration
- `/etc/ldap/ssl` which is the store for TLS credentials, e.g. the private key

For TLS credentials, there are 3 (optionally 4) files which should
be provided from outside the container environment:

- `openldap-key.pem` - the private key for the server in PEM
 format. This file should not be readable by any user except the
 container's OpenLDAP user
- `openldap-cert.pem` - the public key certificate for the server
- `ssl-ca.pem` - the concatenated list of CA certificates which are
 trusted (for client certificate authentication)
- `dhparam.pem` (optional) - a set of Diffie-Hellman parameters which
 are used as base material to set up perfect forward secrecy (PFS)
 cipher suites. Note that if this file is missing, it is
 auto-generated on container start. The generation of this file can
 take a little while, so don't be too surprised if the LDAP server
 doesn't immediately start if the file needs generation.

The certificate (which can be used as both server certificate and
client to other servers in the cluster) should have a subject name
which starts with a CN component, and whose value should be the host
name. For instance if the host on was ldap1.mycorp.com, then the name
on the certificate should be CN=ldap1.mycorp.com (which can be
followed by other fields, but they will be ignored).

For example, to start a container running slapd for the `mycorp.com` domain,
with data stored in `/data/ldap` on the host, use the following (this
example also stores logs in an imported volume, and the SSL credentials on another volume):

    docker run -v /data/ldap:/var/lib/ldap \
               -v /data/slapd-log:/var/log \
               -v /data/ssl-ldap:/etc/ldap/ssl \
               -e LDAP_DOMAIN=mycorp.com \
               -e LDAP_ORGANISATION="My Mega Corporation" \
               -e LDAP_ROOTPASS=s3cr3tpassw0rd \
               -e LDAP_CLUSTER=ldap1.mycorp.com,ldap2.mycorp.com,ldap3.mycorp.com \
               -p 10.0.0.1:389:389 -p 10.0.0.1:636:636 \
               -d ndunbar/slapd

In the above we assume that `ldap1.mycorp.com` is bound to the IP
address 10.0.0.1. The 10.0.0.1 can be omitted if the LDAP service is
to be exposed to multiple IP addresses on the host.

You can find out which port the LDAP server is bound to on the host by running
`docker ps` (or `docker port <container_id> 389`). You could then load an LDIF
file (to set up your directory) like so:

    ldapadd -h localhost -p <host_port> -c -x -D cn=admin,dc=mycorp,dc=com -W -f
data.ldif

**NB**: Please be aware that by default docker will make the LDAP port
accessible from anywhere if the host firewall is unconfigured.
