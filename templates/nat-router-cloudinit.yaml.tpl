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
      Protocol 2                                # Use protocol version 2
      Port ${ ssh_port }                        # SSH port
      MaxAuthTries ${ ssh_max_auth_tries }      # Maximum auth tries in one session (recommended 3)
      LoginGraceTime 20                         # Time to login

      PermitRootLogin no                        # No root login
      PasswordAuthentication no                 # No password auth
      KbdInteractiveAuthentication no           # Unused auth method
      ChallengeResponseAuthentication no        # Unused auth method
      GSSAPIAuthentication no                   # Unused auth method
      IgnoreRhosts yes                          # No hostbased auth
      UseDNS no                                 # Unused auth method
      PubkeyAuthentication yes                  # Only PublicKey auth

      AllowAgentForwarding yes                  # Agent forwarding (can be disabled)
      AllowTcpForwarding yes                    # SSH port forwarding (can be disabled)
      X11Forwarding no                          # Unused forwarding method

      AuthorizedKeysFile .ssh/authorized_keys   # AuthorizedKeysFile
      AllowUsers nat-router                     # Allow only user nat-router
    
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

  # wg-easy Config
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
          networks:
            - wireguard
          volumes:
            - /etc/wireguard:/etc/wireguard:rw
            - /lib/modules:/lib/modules:ro
      networks:
        wireguard:
          driver: bridge

users:
  - name: nat-router
    shell: /bin/bash
    groups: 
%{ if enable_sudo ~}
      - sudo
%{ endif ~}
%{ if enable_sudo ~}
    sudo: 
      - ALL=(ALL) NOPASSWD:ALL
%{ endif ~}
    ssh_authorized_keys:
%{ for key in sshAuthorizedKeys ~}
      - ${key}
%{ endfor ~}

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