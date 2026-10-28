FROM ubuntu:24.04
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      openssh-server iproute2 python3 iptables ca-certificates \
    && mkdir -p /run/sshd \
    && printf 'Port 22\nPort 2222\n' > /etc/ssh/sshd_config.d/ports.conf
