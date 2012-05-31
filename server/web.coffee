coffee  = require("coffee-script")
express = require("express")
fs      = require("fs")
logger  = require("logger")
spawner = require("spawner").init()
util    = require("util")
uuid    = require("node-uuid")

db = require("cloudant").connect("make")

app = express.createServer(
  express.logger()
  express.cookieParser()
  express.bodyParser()
  express.session(secret:process.env.SECRET))

app.post "/make", (req, res, next) ->
  id      = uuid()
  command = req.body.command
  prefix  = req.body.prefix
  deps    = if req.body.deps then JSON.parse(req.body.deps) else []
  log     = logger.init(res, next, id)

  unless req.body.secret is process.env.SECRET
    return log.error "invalid secret"

  # return build id as a header
  res.header "X-Make-Id", id

  # keep the response alive
  setInterval (-> res.write(String.fromCharCode(0) + String.fromCharCode(10))), 1000

  # save build to couchdb
  log.info "saving to couchdb"
  db.save id, command:command, prefix:prefix, deps:deps, (err, doc) ->
    return log.error(util.inspect(err)) if err

    # save uploaded code as an attachment
    log.info "saving attachment - [id:#{doc.id} rev:#{doc.rev}]"
    fs.createReadStream(req.files.code.path).pipe(
      db.saveAttachment {id:doc.id, rev:doc.rev}, {name:"input", "Content-Type":"application/octet-stream"}, (err, data) ->
        return log.error(err.reason) if err && err.error != "conflict"

        res.write "done\n"
        res.write "Building with: #{command}\n"
        log.info  "spawning build"

        env =
          CLOUDANT_URL: process.env.CLOUDANT_URL
          PATH: process.env.PATH

        make = spawner.spawn "bin/make \"#{id}\"", env:env
        make.on "error", (err)  -> log.error(err)
        make.on "data",  (data) -> res.write data
        make.on "exit",  (code) -> res.end())

app.get "/output/:id", (req, res, next) ->
  log    = logger.init(res, next, req.params.id)
  stream = db.getAttachment req.params.id, "output"
  stream.on "error", (err)   -> log.error(err)
  stream.on "data",  (chunk) -> res.write chunk, "binary"
  stream.on "end",           -> res.end()

app.listen process.env.PORT or 3000
