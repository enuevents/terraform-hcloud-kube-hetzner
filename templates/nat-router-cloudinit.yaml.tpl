#cloud-config

# This configuration is for debian 12

package_reboot_if_required: false
package_update: true
package_upgrade: true

# python3-systemd is required on debian 12 for fail2ban to work
packages: 
  - python3-systemd
  - fail2ban

%{ if wireguard_enabled ~}
  - ca-certificates
  - curl
%{ endif ~}

users:
  - name: nat-router
    shell: /bin/bash
%{ if enable_sudo ~}
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
%{ endif ~}
    ssh_authorized_keys:
%{ for key in sshAuthorizedKeys ~}
      - ${key}
%{ endfor ~}

write_files:
  # NAT configuration
  - path: /etc/network/interfaces
    content: |
      auto eth0
      iface eth0 inet dhcp
          post-up echo 1 > /proc/sys/net/ipv4/ip_forward
          post-up iptables -t nat -A POSTROUTING -s '${ private_network_ipv4_range }' -o eth0 -j MASQUERADE
    append: true

  # SSH hardening
  - path: /etc/ssh/sshd_config.d/ssh-hardening.conf
    content: |
      Port ${ ssh_port }
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      ChallengeResponseAuthentication no
      MaxAuthTries ${ ssh_max_auth_tries }
      AllowAgentForwarding yes
      AllowTcpForwarding yes
      X11Forwarding no
      AuthorizedKeysFile .ssh/authorized_keys
      AllowUsers nat-router
    
  # fail2ban backend fallback for debian 12
  - path: /etc/fail2ban/jail.local
    content: |
      [DEFAULT]
      backend = systemd

  # fail2ban configuration
  - path: /etc/fail2ban/jail.d/sshd.local
    content: |
      [sshd]
      enabled = true
      maxretry = 5
      findtime = 10
      bantime = 24h
      logpath = %(sshd_log)s
      backend = %(sshd_backend)s

  # Wireguard UI Config
  - path: /opt/wg-easy/compose.yaml
    content: |
      services:
        wg-easy:
          image: ghcr.io/wg-easy/wg-easy:15
          container_name: wg-easy
          restart: unless-stopped
          ports:
            - 51820:51820/udp
            - 51821:51821/tcp
          cap_add:
            - NET_ADMIN
            - SYS_MODULE
          sysctls:
            - net.ipv4.ip_forward=1
            - net.ipv4.conf.all.src_valid_mark=1
            - net.ipv6.conf.all.disable_ipv6=0
            - net.ipv6.conf.all.forwarding=1
            - net.ipv6.conf.default.forwarding=1
          volumes:
            - /etc/wireguard:/etc/wireguard:rw
            - /lib/modules:/lib/modules:ro

# Apply DNS config
%{ if has_dns_servers ~}
manage_resolv_conf: true
resolv_conf:
  nameservers:
%{ for dns_server in dns_servers ~}
    - ${dns_server}
%{ endfor ~}
%{ endif ~}


runcmd:
%{ if wireguard_enabled ~}
  # Install Docker
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt update
  - apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Start wg-easy
  - docker compose -f /opt/wg-easy/compose.yaml up -d
%{ endif ~}
  
  - systemctl enable fail2ban
  - systemctl start fail2ban
  - systemctl restart sshd
  - systemctl restart networking