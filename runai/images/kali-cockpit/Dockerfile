# HTD · Kali + Cockpit: Kali Linux rolling with the Cockpit web console
# started as the container command. Build and publish it as root on ww1:
#
#   runai/htd-images.py runai/images/kali-cockpit/Dockerfile
#
# The #catalog lines below become its catalog entry (and so its Run:ai
# environment): Cockpit opens as a tool at
# https://<project>-<workload>.runai.htd.local behind Run:ai SSO. Run:ai's
# ingress terminates TLS, so cockpit-ws serves plain HTTP on :9090
# (--for-tls-proxy).
#
# There is no systemd in a pod: the Terminal, Overview and Accounts pages
# work, Services/Logs (systemd, journald) do not.
#
# Login (environment variables of the workload):
#   COCKPIT_USER      Cockpit login user, sudo without password  (kali)
#   COCKPIT_PASSWORD  its password; unset: a random one, printed in the
#                     workload logs (Run:ai → workload → Logs)
#   COCKPIT_AUTH      password (default) | none: no Cockpit login, the session
#                     runs as root and only Run:ai SSO protects it
#   COCKPIT_ORIGINS   extra allowed origins (space separated); the browser
#                     origin https://<project>-<workload>.<domain> is allowed
#
# The container runs as root (image user): Cockpit's login switches users
# through PAM. The nodes are offline, so add the Kali tools you need below
# (kali-tools-* metapackages) and rebuild; apt runs on ww1 at build time.
#
#catalog description: Kali Linux rolling + Cockpit web console (port 9090)
#catalog training: false
#catalog routingMethod: host-base
#catalog connections:
#catalog   - name: Cockpit
#catalog     internalToolInfo:
#catalog       toolType: custom
#catalog       connectionType: ExternalUrl
#catalog       containerPort: 9090
#catalog       externalUrlInfo: {}
ARG WL
FROM ${WL}/kali-rolling:2026-10-31

# Extra Kali packages, e.g. --build-arg KALI_PACKAGES="kali-tools-top10 nmap"
ARG KALI_PACKAGES="nmap netcat-traditional dnsutils iproute2 iputils-ping"
LABEL org.opencontainers.image.title="HTD · Kali + Cockpit" \
      org.opencontainers.image.description="Kali Linux rolling with the Cockpit web console on :9090" \
      org.opencontainers.image.vendor="HTD" \
      io.htd.image="kali-cockpit"

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    COCKPIT_PORT=9090 COCKPIT_USER=kali COCKPIT_AUTH=password \
    HTD_RUNAI_DOMAIN=runai.htd.local

# cockpit-ws/-bridge/-system only: the `cockpit` metapackage pulls
# NetworkManager, udisks2 and PackageKit, none of which run without systemd.
# cockpit-files (file browser) where the Kali repo carries it.
RUN apt-get update \
 && pkgs="cockpit-ws cockpit-bridge cockpit-system" \
 && { ! apt-cache show cockpit-files >/dev/null 2>&1 || pkgs="$pkgs cockpit-files"; } \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      $pkgs sudo passwd openssl tini ca-certificates curl less vim-tiny tmux \
      bash-completion procps $KALI_PACKAGES \
 && rm -rf /var/lib/apt/lists/*

# pam_loginuid cannot write /proc/self/loginuid in an unprivileged pod and
# fails the session ("Permission denied" right after a correct password).
# No machine-id in the base image; cockpit-bridge wants one. cockpit-session
# records logins in lastlog/btmp/wtmp and complains when they are missing.
RUN sed -ri 's/^(session\s+)required(\s+pam_loginuid\.so)/\1optional\2/' /etc/pam.d/cockpit \
 && { [ -s /etc/machine-id ] || openssl rand -hex 16 > /etc/machine-id; } \
 && touch /var/log/lastlog /var/log/wtmp /var/log/btmp && chmod 0600 /var/log/btmp \
 && ws=$(ls /usr/lib/cockpit/cockpit-ws /usr/libexec/cockpit-ws 2>/dev/null | head -1) \
 && test -x "$ws" && ln -sf "$ws" /usr/local/sbin/cockpit-ws \
 && printf 'NAME="HTD · Kali + Cockpit"\nCOCKPIT_VERSION=%s\nBUILT=%s\n' \
      "$(dpkg-query -W -f '${Version}' cockpit-ws)" "$(date -u +%FT%TZ)" > /etc/htd-release

COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/htd-cockpit

EXPOSE 9090
WORKDIR /root
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/htd-cockpit"]
