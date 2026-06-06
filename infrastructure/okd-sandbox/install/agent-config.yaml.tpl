apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: okd-sandbox
# rendezvousIP must be one of the master IPs. Convention: master-1.
rendezvousIP: ${MASTER_1_IP}
hosts:
  - hostname: master-1
    role: master
    interfaces:
      - name: eth0
        macAddress: ${MASTER_1_MAC}
    networkConfig:
      interfaces:
        - name: eth0
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: ${MASTER_1_IP}
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - ${UPSTREAM_DNS}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: eth0
            table-id: 254
    rootDeviceHints:
      deviceName: /dev/sda
  - hostname: master-2
    role: master
    interfaces:
      - name: eth0
        macAddress: ${MASTER_2_MAC}
    networkConfig:
      interfaces:
        - name: eth0
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: ${MASTER_2_IP}
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - ${UPSTREAM_DNS}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: eth0
            table-id: 254
    rootDeviceHints:
      deviceName: /dev/sda
  - hostname: master-3
    role: master
    interfaces:
      - name: eth0
        macAddress: ${MASTER_3_MAC}
    networkConfig:
      interfaces:
        - name: eth0
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: ${MASTER_3_IP}
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - ${UPSTREAM_DNS}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: eth0
            table-id: 254
    rootDeviceHints:
      deviceName: /dev/sda
