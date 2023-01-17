package data

// Data for OCS Config Files -------------------
// Is there a better way to handle this?

var PsiJson = `[
  {
    "module": "sdo_sys",
    "msg": "maxver",
    "value": "1"
  }
]`

// this one is optional, that's why it is separate
var SviJson1 = `
  {
    "module": "sdo_sys",
    "msg": "filedesc",
    "valueLen": -1,
    "valueId": "agent-install-crt_name",
    "enc": "base64"
  },
  {
    "module": "sdo_sys",
    "msg": "write",
    "valueLen": -1,
    "valueId": "agent-install.crt",
    "enc": "base64"
  },`

var SviJson2 = `
  {
    "module": "sdo_sys",
    "msg": "filedesc",
    "valueLen": -1,
    "valueId": "agent-install-cfg_name",
    "enc": "base64"
  },
  {
    "module": "sdo_sys",
    "msg": "write",
    "valueLen": -1,
    "valueId": "agent-install.cfg",
    "enc": "base64"
  },
  {
    "module": "sdo_sys",
    "msg": "filedesc",
    "valueLen": -1,
    "valueId": "agent-install-wrapper-sh_name",
    "enc": "base64"
  },
  {
    "module": "sdo_sys",
    "msg": "write",
    "valueLen": -1,
    "valueId": "agent-install-wrapper.sh",
    "enc": "base64"
  },
  {
    "module": "sdo_sys",
    "msg": "exec",
    "valueLen": -1,
    "valueId": "`

// need to put the uuid between these 2

var SviJson3 = `_exec",
    "enc": "base64"
  }
`
