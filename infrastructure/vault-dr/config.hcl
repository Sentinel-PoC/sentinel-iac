ui = true
disable_mlock = true
storage "file" {
  path = "/vault/file"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}
api_addr = "http://192.168.12.206:8200"
cluster_addr = "http://192.168.12.206:8201"
