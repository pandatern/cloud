import jester, json, tables, times, strutils, httpclient, nimcrypto, uri, strformat, xmltree, xmlparser, std/sysrand, net, os

settings:
  port = Port(8082)

# --- Environment Configuration ---
proc loadEnvConfig(): tuple[accessKey: string, secretKey: string, bucketName: string, region: string, endpoint: string] =
  # Load .env file manually since Nim doesn't have built-in dotenv
  if fileExists(".env"):
    for line in lines(".env"):
      if line.len > 0 and not line.startsWith("#"):
        let parts = line.split("=", 1)
        if parts.len == 2:
          let key = parts[0].strip()
          let value = parts[1].strip(chars = {'"', ' ', '\t', '\n', '\r'})
          putEnv(key, value)
  
  # Global keys are no longer required for multi-user mode.
  # We only load the defaults for region and endpoint, which can be overridden by user-specific env vars.
  result.accessKey = ""
  result.secretKey = ""
  result.bucketName = ""
  result.region = getEnv("AWS_S3_REGION", "us-east-1")
  result.endpoint = getEnv("AWS_S3_ENDPOINT", "s3.tebi.io")


let envConfig = loadEnvConfig()

# --- Session Management ---
type
  UserSession = object
    accessKey: string
    secretKey: string
    bucketName: string
    region: string
    endpoint: string
    createdAt: DateTime

var sessionsStore = initTable[string, UserSession]()

# SECURE Session ID Generation
proc generateSecureSessionId(): string {.gcsafe.} =
  let bytes = urandom(16)
  result = ""
  for b in bytes: result.add(b.toHex(2))

proc getSession(sessionId: string): UserSession {.gcsafe.} =
  if sessionId in sessionsStore:
    return sessionsStore[sessionId]
  else:
    raise newException(ValueError, "Invalid session")

# --- AWS Signature V4 Implementation ---

# NEW: Get service name for Tebi (always use 's3' for compatibility)
proc getService(session: UserSession): string =
  return "s3"  # Use standard S3 service name for Tebi compatibility

# DEFENSIVE TIME CHECK (prevents hours of debugging)
proc validateSystemTime() =
  let nowUtc = now().utc
  if nowUtc.year > 2030 or nowUtc.year < 2020:
    quit("🚨 SYSTEM CLOCK IS INVALID: " & $nowUtc & " - Fix system time with 'sudo ntpdate pool.ntp.org'")
  echo "✅ System time validated: ", nowUtc

proc sha256Hex(data: string): string =
  return ($sha256.digest(data)).toLowerAscii()

proc hmacSha256(key: string, data: string): MDigest[256] =
  return hmac(sha256, key, data)

proc getSignatureKey(secret, dateStamp, regionName, serviceName: string): MDigest[256] =
  let kDate = hmac(sha256, "AWS4" & secret, dateStamp)
  let kRegion = hmac(sha256, kDate.data, regionName)
  let kService = hmac(sha256, kRegion.data, serviceName)
  let kSigning = hmac(sha256, kService.data, "aws4_request")
  return kSigning

# Use virtual-hosted-style URLs for Tebi: https://bucket.endpoint/key
func getS3Url(session: UserSession, key: string): string =
  let proto = if session.endpoint.startsWith("http"): "" else: "https://"
  # For Tebi, use virtual-hosted style: bucket.endpoint/key
  return fmt"{proto}{session.bucketName}.{session.endpoint}/{key}"

# --- Presigned URL Generator ---
proc generatePresignedUrl(session: UserSession, key: string, httpMethod: string = "GET", forceDownload: bool = false): string =
  let
    datetime = now().utc
    amzDate = datetime.format("yyyyMMdd'T'HHmmss'Z'")
    dateStamp = datetime.format("yyyyMMdd")
    service = getService(session)
    region = session.region
    expires = "3600"

    algorithm = "AWS4-HMAC-SHA256"
    credentialScope = fmt"{dateStamp}/{region}/{service}/aws4_request"
    # Use virtual-hosted style host: bucket.endpoint
    host = fmt"{session.bucketName}.{session.endpoint}"
    encodedKey = key.encodeUrl(usePlus=false)

    qAlgo = fmt"X-Amz-Algorithm={algorithm}"
    qCred = fmt"X-Amz-Credential={session.accessKey.encodeUrl()}%2F{credentialScope.encodeUrl()}"
    qDate = fmt"X-Amz-Date={amzDate}"
    qExp = fmt"X-Amz-Expires={expires}"
    
    # Add response-content-disposition for downloads
    responseHeaders = if forceDownload:
        fmt"&response-content-disposition=attachment%3B%20filename%3D{key.encodeUrl()}"
      else:
        ""
    
    qSigned = "X-Amz-SignedHeaders=host"

    canonicalQueryString = fmt"{qAlgo}&{qCred}&{qDate}&{qExp}&{qSigned}{responseHeaders}"
    canonicalHeaders = fmt"host:{host}" & "\n"
    # Virtual-hosted style canonical request path: /key
    canonicalRequestPath = fmt"/{encodedKey}"
    canonicalRequest = httpMethod & "\n" & canonicalRequestPath & "\n" & canonicalQueryString & "\n" & canonicalHeaders & "\n" & "host\nUNSIGNED-PAYLOAD"

    signingKey = getSignatureKey(session.secretKey, dateStamp, region, service)
    stringToSign = algorithm & "\n" & amzDate & "\n" & credentialScope & "\n" & sha256Hex(canonicalRequest)
    signature = ($hmac(sha256, signingKey.data, stringToSign)).toLowerAscii()

    # Virtual-hosted style URL
    fullUrl = getS3Url(session, encodedKey) & fmt"?{canonicalQueryString}&X-Amz-Signature={signature}"

  return fullUrl

# --- XML Parser (Minimal) ---
proc parseS3List(xml: string): JsonNode =
  var resultArray = newJArray()
  try:
    let tree = parseXml(xml)
    
    # Find all Contents elements
    proc findContents(node: XmlNode) =
      if node.kind == xnElement and node.tag == "Contents":
        var item = newJObject()
        for child in node:
          if child.kind == xnElement:
            # Get text content from child text nodes
            var textContent = ""
            for textChild in child:
              if textChild.kind == xnText:
                textContent.add(textChild.text)
            if textContent.len > 0:
              item[child.tag] = %*textContent
        resultArray.add(item)
      
      # Recursively search child elements
      for child in node:
        if child.kind == xnElement:
          findContents(child)
    
    findContents(tree)
  except XmlError as e:
    echo "XML Parsing Error: ", e.msg
  return %*{"Contents": resultArray}

# --- Server-Side S3 Operations ---

proc sendS3Request(session: UserSession, httpMethod: string, key: string, query: string = "", body: string = ""): Response =
  let
    service = getService(session)
    region = session.region
    # Use current time (fixed time was for debugging)
    datetime = now().utc
    amzDate = datetime.format("yyyyMMdd'T'HHmmss'Z'")
    dateStamp = datetime.format("yyyyMMdd")
    # Virtual-hosted style host: bucket.endpoint
    host = fmt"{session.bucketName}.{session.endpoint}"

    # Virtual-hosted style canonical URI - when using virtual hosted style,
    # the bucket is in the host, so canonical URI is just the key path
    encodedKey = key.encodeUrl(usePlus = false)
    canonicalUri = if key.len == 0: "/" else: fmt"/{encodedKey}"

    payloadHash = sha256Hex(body)

    # For HEAD requests, don't include x-amz-content-sha256 (like boto3)  
    canonicalHeaders = if httpMethod == "HEAD":
        fmt"host:{host}" & "\n" & fmt"x-amz-date:{amzDate}" & "\n" & "\n"
      else:
        fmt"host:{host}" & "\n" & fmt"x-amz-content-sha256:{payloadHash}" & "\n" & fmt"x-amz-date:{amzDate}" & "\n" & "\n"
        
    signedHeaders = if httpMethod == "HEAD": "host;x-amz-date" else: "host;x-amz-content-sha256;x-amz-date"
    canonicalRequest = httpMethod & "\n" & canonicalUri & "\n" & query & "\n" & canonicalHeaders & signedHeaders & "\n" & payloadHash

    algorithm = "AWS4-HMAC-SHA256"
    credentialScope = fmt"{dateStamp}/{region}/{service}/aws4_request"
    stringToSign = algorithm & "\n" & amzDate & "\n" & credentialScope & "\n" & sha256Hex(canonicalRequest)
    signingKey = getSignatureKey(session.secretKey, dateStamp, region, service)
    signature = ($hmac(sha256, signingKey.data, stringToSign)).toLowerAscii()

  let client = newHttpClient(userAgent = "PandaCloud/1.0 (Nim)")
  
  # Don't set Host header manually - let the HTTP client handle it
  client.headers = newHttpHeaders({
    "Authorization": fmt"{algorithm} Credential={session.accessKey}/{credentialScope}, SignedHeaders={signedHeaders}, Signature={signature}",
    "X-Amz-Date": amzDate
  })
  
  if httpMethod != "HEAD":
    client.headers["X-Amz-Content-Sha256"] = payloadHash

  # Virtual-hosted style URL
  let url = getS3Url(session, if key.len > 0: encodedKey else: "") & (if query.len > 0: "?" & query else: "")
  echo "🌐 Making request to: ", url

  if httpMethod == "DELETE":
    client.headers["Content-Length"] = "0"

  case httpMethod:
    of "GET": return client.get(url)
    of "DELETE": return client.delete(url)
    of "HEAD": return client.head(url)
    else: raise newException(ValueError, "HTTP method not supported in server-side op")

proc testS3Connection(session: UserSession): bool =
  try:
    echo "✅ System time validated: ", now().utc
    echo "🔐 Testing S3 connection with credentials from .env..."
    let response = sendS3Request(session, "HEAD", "", "")
    echo "📡 S3 Connection test: ", response.code, " ", response.status
    # For Tebi S3, we should accept 200 (OK) or 404 (bucket access but no object)
    # 403 usually means invalid credentials, so let's be more strict
    return response.code.is2xx
  except Exception as e:
    echo "❌ S3 Connection Error: ", e.msg
    return false

proc listS3Objects(session: UserSession): JsonNode =
  try:
    echo "📁 Listing S3 objects..."

    # Use sendS3Request for bucket operations with Authorization header
    let response = sendS3Request(session, "GET", "", "list-type=2", "")

    echo "📊 S3 List Response: ", response.code, " ", response.status
    let responseBody = response.body

    if response.code != Http200:
      echo "❌ S3 List failed: ", response.code, " ", response.status
      # Try to parse error message from S3
      try:
        let xml = parseXml(responseBody)
        
        # Find Message element recursively
        proc findMessage(node: XmlNode): string =
          if node.kind == xnElement and node.tag == "Message":
            # Get text content from child text nodes
            for child in node:
              if child.kind == xnText:
                return child.text
          # Recursively search child elements
          for child in node:
            if child.kind == xnElement:
              let msg = findMessage(child)
              if msg.len > 0:
                return msg
          return ""
        
        let msg = findMessage(xml)
        if msg.len > 0:
          return %*{"error": msg}
        else:
          return %*{"error": "S3 request failed with code " & $response.code}
      except:
        return %*{"error": "S3 request failed with code " & $response.code}

    return parseS3List(responseBody) # Use the XML parser
  except Exception as e:
    echo "❌ Exception in listS3Objects: ", e.msg
    return %*{"error": e.msg}

proc deleteFromS3(session: UserSession, key: string): bool =
  try:
    echo "Attempting to delete from S3, key: ", key
    let resp = sendS3Request(session, "DELETE", key)
    echo "S3 DELETE response code: ", resp.code
    echo "S3 DELETE response status: ", resp.status
    echo "S3 DELETE response body: ", resp.body
    return resp.code.is2xx
  except Exception as e:
    echo "Exception in deleteFromS3: ", e.msg
    return false

# --- Frontend ---
const htmlFrontend = staticRead("public/index.html")

# --- Routes ---
routes:
  options "/*":
    # Respond to CORS preflight requests
    resp(Http200, [
      ("Access-Control-Allow-Origin", "*"),
      ("Access-Control-Allow-Methods", "GET, POST, DELETE, PUT, HEAD, OPTIONS"),
      ("Access-Control-Allow-Headers", "Content-Type, X-Session-ID")
    ], "")

  get "/":
    resp htmlFrontend

  post "/api/login":
    try:
      let body = parseJson(request.body)
      let userId = body["userId"].getStr()
      let password = body["password"].getStr()

      if userId.len == 0 or password.len == 0:
        raise newException(ValueError, "User ID and Password are required")

      # Construct env var names
      let userPassEnv = "USER_" & userId & "_PASSWORD"
      let userAccessKeyEnv = "USER_" & userId & "_AWS_ACCESS_KEY_ID"
      let userSecretKeyEnv = "USER_" & userId & "_AWS_SECRET_ACCESS_KEY"
      let userBucketEnv = "USER_" & userId & "_AWS_S3_BUCKET"
      let userRegionEnv = "USER_" & userId & "_AWS_S3_REGION"
      let userEndpointEnv = "USER_" & userId & "_AWS_S3_ENDPOINT"

      let storedPassword = getEnv(userPassEnv)

      if storedPassword.len == 0:
        resp %*{"success": false, "error": "Invalid User ID"}
      elif storedPassword != password:
        resp %*{"success": false, "error": "Invalid Password"}
      else:
        # Password is correct, now get S3 credentials
        let accessKey = getEnv(userAccessKeyEnv)
        let secretKey = getEnv(userSecretKeyEnv)
        let bucketName = getEnv(userBucketEnv)

        if accessKey.len == 0 or secretKey.len == 0 or bucketName.len == 0:
          echo "❌ Configuration error for user: ", userId, ". Missing S3 credentials in .env file."
          resp %*{"success": false, "error": "Server configuration error for this user."}
        else:
          let session = UserSession(
            accessKey: accessKey,
            secretKey: secretKey,
            bucketName: bucketName,
            region: getEnv(userRegionEnv, envConfig.region), # Fallback to default region
            endpoint: getEnv(userEndpointEnv, envConfig.endpoint), # Fallback to default endpoint
            createdAt: now()
          )
          
          echo "🔐 User '", userId, "' authenticated. Testing connection..."
          
          if testS3Connection(session):
            let sessionId = generateSecureSessionId()
            sessionsStore[sessionId] = session
            resp %*{"success": true, "sessionId": sessionId}
          else:
            resp %*{"success": false, "error": "Connection to S3 failed. Please check the credentials for this user."}

    except Exception as e:
      resp %*{"success": false, "error": "Login failed: " & e.msg}

  get "/api/files":
    try:
      let sessionId = $request.headers["X-Session-ID"]
      let session = getSession(sessionId)
      let s3Data = listS3Objects(session)

      if s3Data.hasKey("error"):
        resp %*{"success": false, "error": s3Data["error"]}
      else:
        var files = newJArray()
        if s3Data.hasKey("Contents"):
          for item in s3Data["Contents"]:
            files.add(%*{
              "key": item["Key"].getStr(),
              "size": item["Size"].getStr(),
              "presignedUrl": generatePresignedUrl(session, item["Key"].getStr(), "GET", false),
              "downloadUrl": generatePresignedUrl(session, item["Key"].getStr(), "GET", true)
            })
        resp %*{"success": true, "files": files}
    except Exception as e:
      resp %*{"success": false, "error": e.msg}

  post "/api/sign-upload":
    try:
      let sessionId = $request.headers["X-Session-ID"]
      let session = getSession(sessionId)
      let body = parseJson(request.body)
      let key = body["key"].getStr()
      let url = generatePresignedUrl(session, key, "PUT")
      resp %*{"success": true, "url": url}
    except Exception as e:
      resp %*{"success": false, "error": "Signing failed: " & e.msg}

  post "/api/delete":
    try:
      echo "--- DELETE REQUEST ---"
      let sessionId = $request.headers["X-Session-ID"]
      echo "Session ID: ", sessionId
      let session = getSession(sessionId)
      let requestBody = request.body
      echo "Request Body: ", requestBody
      let key = parseJson(requestBody)["key"].getStr()
      echo "Key to delete: ", key
      let success = deleteFromS3(session, key)
      echo "Delete success: ", success
      if success:
        resp(Http200, [
          ("Access-Control-Allow-Origin", "*"),
          ("Content-Type", "application/json")
        ], $(%*{"success": true}))
      else:
        resp(Http200, [
          ("Access-Control-Allow-Origin", "*"),
          ("Content-Type", "application/json")
        ], $(%*{"success": false, "error": "Delete failed on server."}))
    except Exception as e:
      echo "Error in /api/delete: ", e.msg
      resp(Http200, [
        ("Access-Control-Allow-Origin", "*"),
        ("Content-Type", "application/json")
      ], $(%*{"success": false, "error": e.msg}))

echo "🐼 Panda Cloud - http://localhost:8082"
echo "📁 Bucket: ", envConfig.bucketName, " | 🌐 Endpoint: ", envConfig.endpoint
# Validate system time at startup
validateSystemTime()
runForever()
