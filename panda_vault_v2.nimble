version       = "0.1.0"
author        = "Panda"
description   = "A simple S3 file vault"
license       = "proprietary"
srcDir        = "."
bin           = @["panda_vault_v2"]

requires "nim >= 1.6.0", "jester", "nimcrypto"