apiVersion: v1
baseDomain: sandbox.208.haist.farm
metadata:
  name: okd-sandbox
controlPlane:
  name: master
  replicas: 3
  hyperthreading: Enabled
  architecture: amd64
compute:
  - name: worker
    replicas: 0
    hyperthreading: Enabled
    architecture: amd64
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
  machineNetwork:
    - cidr: ${MACHINE_NETWORK_CIDR}
  networkType: OVNKubernetes
platform:
  baremetal:
    apiVIPs:
      - ${API_VIP}
    ingressVIPs:
      - ${INGRESS_VIP}
pullSecret: '${PULL_SECRET}'
sshKey: |
  ${SSH_PUBLIC_KEY}
# Per Q2: internet egress to quay.io/okd is allowed for first bring-up.
# imageContentSources / additionalTrustBundle for the internal mirror are
# left commented; mirror-fill-in is a follow-up issue. When we cut over to
# the internal mirror, uncomment these and re-render.
# additionalTrustBundle: |
#   ${MIRROR_CA_PEM_INDENTED}
# imageContentSources:
#   - mirrors:
#       - ${MIRROR_REGISTRY}/okd
#     source: quay.io/okd
#   - mirrors:
#       - ${MIRROR_REGISTRY}/okd
#     source: registry.ci.openshift.org/origin
