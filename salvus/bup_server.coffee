#################################################################
#
# bup_server -- a node.js program that provides a TCP server
# that is used by the hubs to organize project storage
#
#  (c) William Stein, 2014
#
#  NOT released under any open source license.
#
#################################################################

async     = require('async')
winston   = require('winston')
program   = require('commander')
daemon    = require('start-stop-daemon')
net       = require('net')
fs        = require('fs')
message   = require('message')
misc      = require('misc')
misc_node = require('misc_node')
uuid      = require('node-uuid')
cassandra = require('cassandra')
cql       = require("node-cassandra-cql")

# Set the log level
winston.remove(winston.transports.Console)
winston.add(winston.transports.Console, level: 'debug')

{defaults, required} = misc

TIMEOUT = 60*60

# never do a save action more frequently than this - more precisely, saves just get
# ignored until this much time elapses *and* an interesting file changes.
MIN_SAVE_INTERVAL_S = 60

STORAGE_SERVERS_UPDATE_INTERVAL_S = 180  # How frequently (in seconds)  to query the database for the list of storage servers

IDLE_TIMEOUT_INTERVAL_S = 120   # The idle timeout checker runs once ever this many seconds.

CONF = "/bup/conf"
fs.exists CONF, (exists) ->
    if exists
        # only makes sense to do this on server nodes...
        fs.chmod(CONF, 0o700)     # just in case...

DATA = 'data'


###########################
## server-side: Storage server code
###########################

bup_storage = (opts) =>
    opts = defaults opts,
        args    : required
        timeout : TIMEOUT
        cb      : required
    winston.debug("bup_storage: running #{misc.to_json(opts.args)}")
    misc_node.execute_code
        command : "sudo"
        args    : ["/usr/local/bin/bup_storage.py"].concat(opts.args)
        timeout : opts.timeout
        path    : process.cwd()
        cb      : (err, output) =>
            winston.debug("bup_storage: finished running #{misc.to_json(opts.args)} -- #{err}")
            if err
                if output?.stderr
                    opts.cb(output.stderr)
                else
                    opts.cb(err)
            else
                opts.cb(undefined, if output.stdout then misc.from_json(output.stdout) else undefined)


# A single project from the point of view of the storage server
class Project
    constructor: (opts) ->
        opts = defaults opts,
            project_id : required
            verbose    : true

        @project_id      = opts.project_id
        @verbose         = opts.verbose

    dbg: (f, args, m) =>
        if @verbose
            winston.debug("Project(#{@project_id}).#{f}(#{misc.to_json(args)}): #{m}")

    exec: (opts) =>
        opts = defaults opts,
            args    : required
            timeout : TIMEOUT
            cb      : required

        args = []
        for a in opts.args
            args.push(a)
        args.push(@project_id)

        @dbg("exec", opts.args, "executing bup_storage.py script")
        bup_storage
            args    : args
            timeout : opts.timeout
            cb      : opts.cb

    action: (opts) =>
        opts = defaults opts,
            action  : required    # sync, save, etc.
            timeout : TIMEOUT
            param   : undefined   # if given, should be an array or string
            cb      : undefined   # cb?(err)

        @dbg('action', opts)
        if opts.action == 'get_state'
            @get_state(cb : (err, state) => opts.cb?(err, state))
            return


        state  = undefined
        result = undefined
        # STATES: stopped, starting, running, restarting, stopping, saving, error
        async.series([
            (cb) =>
                @get_state
                    cb : (err, s) =>
                        state = s; cb(err)
            (cb) =>
                switch opts.action
                    when 'start'
                        if state in ['stopped', 'error'] or opts.param=='force'
                            @state = 'starting'
                            @_action
                                action  : 'start'
                                param   : opts.param
                                timeout : opts.timeout
                                cb      : (err, r) =>
                                    result = r
                                    if err
                                        @dbg("action", opts, "start -- error starting=#{err}")
                                        @state = 'error'
                                    else
                                        @dbg("action", opts, "started successfully -- changing state to running")
                                        @state = 'running'
                                    cb(err)
                        else
                            cb()

                    when 'restart'
                        if state in ['running', 'error'] or opts.param=='force'
                            @state = 'restarting'
                            @_action
                                action  : 'restart'
                                param   : opts.param
                                timeout : opts.timeout
                                cb      : (err, r) =>
                                    result = r
                                    if err
                                        @dbg("action", opts, "failed to restart -- #{err}")
                                        @state = 'error'
                                    else
                                        @dbg("action", opts, "restarted successfully -- changing state to running")
                                        @state = 'running'
                                    cb(err)
                        else
                            cb()

                    when 'stop'
                        if state in ['running', 'error'] or opts.param=='force'
                            @state = 'stopping'
                            @_action
                                action  : 'stop'
                                param   : opts.param
                                timeout : opts.timeout
                                cb      : (err, r) =>
                                    result = r
                                    if err
                                        @dbg("action", opts, "failed to stop -- #{err}")
                                        @state = 'error'
                                    else
                                        @dbg("action", opts, "stopped successfully -- changing state to stopped")
                                        @state = 'stopped'
                                    cb(err)
                        else
                            cb()


                    when 'save'
                        if state in ['running'] or opts.param=='force'
                            @state = 'saving'
                            @_action
                                action  : 'save'
                                param   : opts.param
                                timeout : opts.timeout
                                cb      : (err, r) =>
                                    result = r
                                    if err
                                        @dbg("action", opts, "failed to save -- #{err}")
                                        @state = 'error'
                                    else
                                        @dbg("action", opts, "saved successfully -- changing state from saving back to running")
                                        @state = 'running'
                                    cb(err)
                        else
                            cb()

                    else
                        @_action
                            action  : opts.action
                            param   : opts.param
                            timeout : opts.timeout
                            cb      : (err, r) =>
                                result = r
                                cb(err)
        ], (err) =>
            opts.cb?(err, result)
        )

    _action: (opts) =>
        opts = defaults opts,
            action  : required    # sync, save, etc.
            param   : undefined   # if given, should be an array or string
            timeout : TIMEOUT
            cb      : undefined   # cb?(err)
        dbg = (m) => @dbg("_action", opts, m)
        dbg()
        switch opts.action
            when "get_state"
                @get_state
                    cb : opts.cb

            else

                dbg("Doing action #{opts.action} that involves executing script")
                args = [opts.action]
                if opts.param? and opts.param != 'force'
                    if typeof opts.param == 'string'
                        opts.param = misc.split(opts.param)  # turn it into an array
                    args = args.concat(opts.param)
                @exec
                    args    : args
                    timeout : opts.timeout
                    cb      : opts.cb

    get_state: (opts) =>
        opts = defaults opts,
            cb : required

        if @state?
            if @state not in ['starting', 'stopping', 'restarting']   # stopped, running, saving, error
                winston.debug("get_state -- confirming running status")
                @_action
                    action : 'status'
                    param  : '--running'
                    cb     : (err, status) =>
                        winston.debug("get_state -- confirming based on status=#{misc.to_json(status)}")
                        if err
                            @state = 'error'
                        else if status.running
                            # set @state to a running state: either 'saving' or 'running'
                            if @state != 'saving'
                                @state = 'running'
                        else
                            @state = 'stopped'
                        opts.cb(undefined, @state)
            else
                winston.debug("get_state -- trusting running status since @state=#{@state}")
                opts.cb(undefined, @state)
            return
        # We -- the server running on this compute node -- don't know the state of this project.
        # This might happen if the server were restarted, the machine rebooted, the project not
        # ever started, here, etc.  So we run a script and try to guess a state.
        @_action
            action : 'status'
            cb     : (err, status) =>
                @dbg("get_state",'',"basing on status=#{misc.to_json(status)}")
                if err
                    @state = 'error'
                else if status.running
                    @state = 'running'
                else
                    @state = 'stopped'
                opts.cb(undefined, @state)


projects = {}
get_project = (project_id) ->
    if not projects[project_id]?
        projects[project_id] = new Project(project_id: project_id)
    return projects[project_id]

handle_mesg = (socket, mesg) ->
    winston.debug("storage_server: handling '#{misc.to_safe_str(mesg)}'")
    id = mesg.id
    if mesg.event == 'storage'
        if mesg.action == 'server_id'
            mesg.server_id = SERVER_ID
            socket.write_mesg('json', mesg)
        else
            t = misc.walltime()
            if mesg.action == 'sync'
                if not mesg.param?
                    mesg.param = []
            project = get_project(mesg.project_id)
            project.action
                action : mesg.action
                param  : mesg.param
                cb     : (err, result) ->
                    if err
                        resp = message.error(error:err, id:id)
                    else
                        resp = message.success(id:id)
                    if result?
                        resp.result = result
                    resp.time_s = misc.walltime(t)
                    socket.write_mesg('json', resp)
    else
        socket.write_mesg('json', message.error(id:id, error:"unknown event type: '#{mesg.event}'"))

up_since = undefined
init_up_since = (cb) ->
    fs.readFile "/proc/uptime", (err, data) ->
        if err
            cb(err)
        else
            up_since = cassandra.seconds_ago(misc.split(data.toString())[0])
            cb()

SERVER_ID = undefined

init_server_id = (cb) ->
    file = program.server_id_file
    fs.exists file, (exists) ->
        if not exists
            SERVER_ID = uuid.v4()
            fs.writeFile file, SERVER_ID, (err) ->
                if err
                    winston.debug("Error writing server_id file!")
                    cb(err)
                else
                    winston.debug("Wrote new SERVER_ID =#{SERVER_ID}")
                    cb()
        else
            fs.readFile file, (err, data) ->
                if err
                    cb(err)
                else
                    SERVER_ID = data.toString()
                    cb()


idle_timeout = () ->
    dbg = (m) -> winston.debug("idle_timeout: #{m}")
    dbg('Periodic check for projects that are running and call "kill --only_if_idle" on them all.')
    uids = []
    async.series([
        (cb) ->
            dbg("get uids of active projects")
            misc_node.execute_code
                command : "ps -Ao uid| sort |uniq"
                timeout : 30
                bash    : true
                cb      : (err, output) =>
                    if err
                        cb(err); return
                    v = output.stdout.split('\n')
                    dbg("got #{v.length} uids")
                    for uid in v
                        uid = parseInt(uid)
                        if uid > 65535
                            uids.push(uid)
                    cb()
        (cb) ->
            f = (uid, c) ->
                misc_node.execute_code
                    command : "getent passwd '#{uid}' | cut -d: -f6"
                    timeout : 30
                    bash    : true
                    cb      : (err, output) =>
                        if err
                            dbg("WARNING: error getting username for uid #{uid} -- #{err}")
                            c()
                        else if output.stdout.indexOf('nobody') != -1
                            c()
                        else
                            dbg("#{uid} --> #{output.stdout}")
                            v = output.stdout.split('/')
                            project_id = v[v.length-1].trim()
                            get_project(project_id).action
                                action : 'stop'
                                param  : '--only_if_idle'
                                cb     : (err) ->
                                    if err
                                        dbg("WARNING: error stopping #{project_id} -- #{err}")
                                    c()
            async.map(uids, f, cb)
    ])


start_tcp_server = (cb) ->
    winston.info("starting tcp server...")

    setInterval(idle_timeout, IDLE_TIMEOUT_INTERVAL_S * 1000)

    server = net.createServer (socket) ->
        winston.debug("received connection")
        socket.id = uuid.v4()
        misc_node.unlock_socket socket, secret_token, (err) ->
            if err
                winston.debug("ERROR: unable to unlock socket -- #{err}")
            else
                winston.debug("unlocked connection")
                misc_node.enable_mesg(socket)
                socket.on 'mesg', (type, mesg) ->
                    if type == "json"   # other types ignored -- we only deal with json
                        winston.debug("received mesg #{misc.to_safe_str(mesg)}")
                        try
                            handle_mesg(socket, mesg)
                        catch e
                            winston.debug(new Error().stack)
                            winston.error "ERROR: '#{e}' handling message '#{misc.to_safe_str(mesg)}'"

    get_port = (c) ->
        if program.port
            c()
        else
            # attempt once to use the same port as in port file, if there is one
            fs.exists program.portfile, (exists) ->
                if not exists
                    program.port = 0
                    c()
                else
                    fs.readFile program.portfile, (err, data) ->
                        if err
                            program.port = 0
                            c()
                        else
                            program.port = data.toString()
                            c()
    listen = (c) ->
        winston.debug("trying port #{program.port}")
        server.listen program.port, program.address, (err) ->
            if err
                winston.debug("failed to listen to #{program.port} -- #{err}")
                c(err)
            else
                program.port = server.address().port
                fs.writeFile(program.portfile, program.port, cb)
                winston.debug("listening on #{program.address}:#{program.port}")
                c()
    get_port () ->
        listen (err) ->
            if err
                winston.debug("fail so let OS assign port...")
                program.port = 0
                listen()


secret_token = undefined
read_secret_token = (cb) ->
    if secret_token?
        cb()
        return
    winston.debug("read_secret_token")

    async.series([
        # Read or create the file; after this step the variable secret_token
        # is set and the file exists.
        (cb) ->
            fs.exists program.secret_file, (exists) ->
                if exists
                    winston.debug("read '#{program.secret_file}'")
                    fs.readFile program.secret_file, (err, buf) ->
                        secret_token = buf.toString().trim()
                        cb()
                else
                    winston.debug("create '#{program.secret_file}'")
                    require('crypto').randomBytes 64, (ex, buf) ->
                        secret_token = buf.toString('base64')
                        fs.writeFile(program.secret_file, secret_token, cb)

        # Ensure restrictive permissions on the secret token file.
        (cb) ->
            fs.chmod(program.secret_file, 0o600, cb)
    ], cb)


start_server = () ->
    winston.debug("start_server")
    async.series [init_server_id, init_up_since, read_secret_token, start_tcp_server], (err) ->
        if err
            winston.debug("Error starting server -- #{err}")
        else
            winston.debug("Successfully started server.")


###########################
## GlobalClient -- client for working with *all* storage/compute servers
###########################

###

# Adding new servers form the coffeescript command line and pushing out config files:

c=require('cassandra');x={};d=new c.Salvus(hosts:['10.1.11.2'], keyspace:'salvus', username:'salvus', password:fs.readFileSync('/home/salvus/salvus/salvus/data/secrets/cassandra/salvus').toString().trim(),consistency:1,cb:((e,d)->console.log(e);x.d=d))

require('bup_server').global_client(database:x.d, cb:(e,c)->x.e=e;x.c=c)

(x.c.register_server(host:"10.1.#{i}.5",dc:0,cb:console.log) for i in [10..21])

(x.c.register_server(host:"10.1.#{i}.5",dc:1,cb:console.log) for i in [1..7])

(x.c.register_server(host:"10.3.#{i}.4",dc:1,cb:console.log) for i in [1..8])

x.c.push_servers_files(cb:console.log)

###

# A project viewed globally (but from a particular hub)
class GlobalProject
    constructor: (@project_id, @global_client) ->
        @database = @global_client.database

    get_location_pref: (cb) =>
        @database.select_one
            table   : "projects"
            columns : ["bup_location"]
            where   : {project_id : @project_id}
            cb      : cb

    set_location_pref: (server_id, cb) =>
        @database.update
            table : "projects"
            set   : {bup_location : server_id}
            where   : {project_id : @project_id}
            cb      : cb


    # starts project if necessary, waits until it is running, and
    # gets the hostname port where the local hub is serving.
    local_hub_address: (opts) =>
        opts = defaults opts,
            timeout : 30
            cb : required      # cb(err, {host:hostname, port:port, status:status})
        if @_local_hub_address_queue?
            @_local_hub_address_queue.push(opts.cb)
        else
           @_local_hub_address_queue = [opts.cb]
           @_local_hub_address
               timeout : opts.timeout
               cb      : (err, r) =>
                   for cb in @_local_hub_address_queue
                       cb(err, r)
                   delete @_local_hub_address_queue

    _local_hub_address: (opts) =>
        opts = defaults opts,
            timeout : 90
            cb : required      # cb(err, {host:hostname, port:port})
        dbg = (m) -> winston.info("local_hub_address(#{@project_id}): #{m}")
        dbg()
        server_id = undefined
        port      = undefined
        status    = undefined
        attempt = (cb) =>
            dbg("making an attempt to start")
            async.series([
                (cb) =>
                    dbg("see if host running")
                    @get_host_where_running
                        cb : (err, s) =>
                            port = undefined
                            server_id = s
                            cb(err)
                (cb) =>
                    if not server_id?
                        dbg("not running anywhere, so try to start")
                        @start(cb:cb)
                    else
                        dbg("running or starting somewhere, so test it out")
                        @project
                            server_id : server_id
                            cb        : (err, project) =>
                                if err
                                    cb(err)
                                else
                                    project.status
                                        cb : (err, _status) =>
                                            status = _status
                                            port = status?['local_hub.port']
                                            cb()
                (cb) =>
                    if port?
                        dbg("success -- we got our host")
                        @_update_project_settings()   # non-blocking -- might as well do this on success.
                        cb()
                    else
                        dbg("fail -- not working yet")
                        cb(true)
             ], cb)

        t = misc.walltime()
        f = () =>
            if misc.walltime() - t > opts.timeout
                # give up
                opts.cb("unable to start project running somewhere within about #{opts.timeout} seconds")
            else
                # try to open...
                attempt (err) =>
                    if err
                        dbg("attempt to get address failed -- #{err}; try again in 5 seconds")
                        setTimeout(f, 5000)
                    else
                        # success!?
                        host = @global_client.servers[server_id]?.host
                        if not host?
                            opts.cb("unknown server #{server_id}")
                        else
                            opts.cb(undefined, {host:host, port:port, status:status})
         f()


    _update_project_settings: (cb) =>
        dbg = (m) -> winston.debug("GlobalProject.update_project_settings(#{@project_id}): #{m}")
        dbg()
        @database.select_one
            table   : 'projects'
            columns : ['settings']
            where   : {project_id: @project_id}
            cb      : (err, result) =>
                dbg("got settings from database: #{misc.to_json(result[0])}")
                if err or not result[0]?   # result[0] = undefined if no special settings
                    cb?(err)
                else
                    opts = result[0]
                    opts.cb = (err) =>
                        if err
                            dbg("set settings for project -- #{err}")
                        else
                            dbg("successful set settings")
                        cb?(err)
                    @settings(opts)

    start: (opts) =>
        opts = defaults opts,
            cb     : undefined
        dbg = (m) -> winston.debug("GlobalProject.start(#{@project_id}): #{m}")
        dbg()
        state     = undefined
        project   = undefined
        server_id = undefined
        target    = undefined

        async.series([
            (cb) =>
                @get_location_pref (err, result) =>
                    if not err and result?
                        dbg("setting prefered start target to #{result[0]}")
                        target = result[0]
                        cb()
                    else
                        cb(err)
            (cb) =>
                dbg("get global state of the project")
                @get_state
                    cb : (err, s) =>
                        state = s; cb(err)
            (cb) =>
                running_on = (server_id for server_id, s of state when s in ['running', 'starting', 'restarting', 'saving'])
                if running_on.length == 0
                    dbg("find a place to run project")
                    v = (server_id for server_id, s of state when s not in ['error'])
                    if v.length == 0
                        v = misc.keys(state)
                    if target? and v.length > 1
                        v = (server_id for server_id in v when server_id != @_next_start_avoid)
                        delete @_next_start_avoid
                    if target? and target in v
                        server_id = target
                        cb()
                    else
                        dbg("order good servers by most recent save time, and choose randomly from those")
                        @get_last_save
                            cb : (err, last_save) =>
                                if err
                                    cb(err)
                                else
                                    for server_id in v
                                        if not last_save[server_id]?
                                            last_save[server_id] = 0
                                    w = []
                                    for server_id, timestamp of last_save
                                        if server_id not in v
                                            delete last_save[server_id]
                                        else
                                            w.push(timestamp)
                                    if w.length > 0
                                        w.sort()
                                        newest = w[w.length-1]
                                        # we use date subtraction below because equality testing of dates does *NOT* work correctly
                                        # for our purposes, maybe due to slight rounding errors and milliseconds.  And strategically
                                        # it also makes sense to lump 2 projects with a save within a few seconds in our random choice.
                                        v = (server_id for server_id in v when Math.abs(last_save[server_id] - newest) < 10*1000)
                                    dbg("choosing randomly from #{v.length} choices with optimal save time")
                                    server_id = misc.random_choice(v)
                                    dbg("our choice is #{server_id}")
                                    cb()

                else if running_on.length == 1
                    dbg("done -- nothing further to do -- project already running on one host")
                    cb()
                else
                    dbg("project running on more than one host -- repair by killing all but first; this will force any clients to move to the correct host when their connections get dropped")
                    running_on.sort() # sort so any client doing the same thing will kill the same other ones.
                    @_stop_all(running_on.slice(1))
                    cb()

            (cb) =>
                if not server_id?  # already running
                    cb(); return
                dbg("got project on #{server_id} so we can start it there")
                @project
                    server_id : server_id
                    cb        : (err, p) =>
                        project = p; cb (err)
            (cb) =>
                if not server_id?  # already running
                    cb(); return
                dbg("start project on #{server_id}")
                project.start
                    cb : (err) =>
                        if not err
                            dbg("success -- record that #{server_id} is now our preferred start location")
                            @set_location_pref(server_id)
                        cb(err)
        ], (err) => opts.cb?(err))


    restart: (opts) =>
        dbg = (m) -> winston.debug("GlobalProject.restart(#{@project_id}): #{m}")
        dbg()
        @running_project
            cb : (err, project) =>
                if err
                    dbg("unable to determine running project -- #{err}")
                    opts.cb(err)
                else if project?
                    dbg("project is running somewhere, so restart it there")
                    project.restart(opts)
                else
                    dbg("project not running anywhere, so start it somewhere")
                    @start(opts)


    save: (opts) =>
        opts = defaults opts,
            cb : undefined
        dbg = (m) -> winston.debug("GlobalProject.save(#{@project_id}): #{m}")
        dbg()

        need_to_save = false
        project      = undefined
        targets      = undefined
        server_id    = undefined
        errors       = []
        async.series([
            (cb) =>
                dbg("figure out where/if project is running")
                @get_host_where_running
                    cb : (err, s) =>
                        server_id = s
                        if err
                            cb(err)
                        else if not server_id?
                            dbg("not running anywhere -- nothing to save")
                            cb()
                        else if @state?[server_id] == 'saving'
                            dbg("already saving -- nothing to do")
                            cb()
                        else
                            need_to_save = true
                            cb()
            (cb) =>
                if not need_to_save
                    cb(); return
                dbg("get the project itself")
                @project
                    server_id : server_id
                    cb        : (err, p) =>
                        project = p; cb(err)
            (cb) =>
                if not need_to_save
                    cb(); return
                dbg("get the save targets for replication")
                @get_last_save
                    cb : (err, last_save) =>
                        if err
                            cb(err)
                        else
                            if last_save?
                                # targets are all ip addresses of servers we've replicated to so far (if any)
                                dbg("last_save = #{misc.to_json(last_save)}")
                                targets = (@global_client.servers[x].host for x,t of last_save when x != server_id)
                                dbg("targets = #{misc.to_json(targets)}")
                                # leave undefined otherwise -- will use consistent hashing to do initial save
                            cb()
            (cb) =>
                if not need_to_save
                    cb(); return
                dbg("actually save the project and sync to targets=#{misc.to_json(targets)}")
                project.save
                    targets : targets
                    cb      : (err, result) =>
                        r = result?.result
                        dbg("RESULT = #{misc.to_json(result)}")
                        if not err and r? and r.timestamp? and r.files_saved > 0
                            dbg("record info about saving #{r.files_saved} files in database")
                            last_save = {}
                            last_save[server_id] = r.timestamp*1000
                            if r.sync?
                                for x in r.sync
                                    s = @global_client.servers.by_host[x.host].server_id
                                    if not x.error?
                                        last_save[s] = r.timestamp*1000
                                    else
                                        # this replication failed
                                        errors.push("replication to #{s} failed -- #{x.error}")
                            @set_last_save
                                last_save        : last_save
                                bup_repo_size_kb : r.bup_repo_size_kb
                                cb               : cb
                        else
                            cb(err)
        ], (err) =>
            if err
                opts.cb?(err)
            else if errors.length > 0
                opts.cb?(errors)
            else
                opts.cb?()
        )


    # if some project is actually running, return it; otherwise undefined
    running_project: (opts) =>
        opts = defaults opts,
            cb : required   # (err, project)
        @get_host_where_running
            cb : (err, server_id) =>
                if err
                    opts.cb?(err)
                else if not server_id?
                    opts.cb?() # not running anywhere
                else
                    @project
                        server_id : server_id
                        cb        : opts.cb

    # return status of *running* project, if running somewhere, or {}.
    status: (opts) =>
        @running_project
            cb : (err, project) =>
                if err
                    opts.cb(err)
                else if project?
                    project.status(opts)
                else
                    opts.cb(undefined, {})  # no running project, so no status

    # set settings of running project, if running somewhere, or an error.
    settings: (opts) =>
        @running_project
            cb : (err, project) =>
                if err
                    opts.cb?(err)
                else if project?
                    project.settings(opts)
                else
                    opts.cb?("project not running anywhere")

    stop: (opts) =>
        opts = defaults opts,
            cb : undefined
        @get_host_where_running
            cb : (err, server_id) =>
                if err
                    opts.cb?(err)
                else if not server_id?
                    opts.cb?() # not running anywhere -- nothing to save
                else
                    @_stop_all([server_id])
                    opts.cb?()

    # change the location preference for the next start, and attempts to stop
    # if running somewhere now.
    move: (opts) =>
        opts = defaults opts,
            target : undefined
            cb     : undefined
        dbg = (m) -> winston.debug("GlobalProject.move(#{@project_id}): #{m}")
        dbg()
        async.series([
            (cb) =>
                if opts.target?
                    dbg("set next open location preference -- #{err}")
                    @set_location_pref(opts.target, cb)
                else
                    cb()
            (cb) =>
                @get_host_where_running
                    cb : (err, server_id) =>
                        if err
                            dbg("error determining info about running status -- #{err}")
                            cb(err)
                        else
                            @_next_start_avoid = server_id
                            if server_id?
                                # next start will happen on new machine...
                                @stop
                                    cb: (err) =>
                                        dbg("non-fatal error stopping -- expected given that move is used when host is down -- #{err}")
                                        cb()
                            else
                                cb()
        ], (err) =>
            dbg("move completed -- #{err}")
            opts.cb?(err)
        )

    get_host_where_running: (opts) =>
        opts = defaults opts,
            cb : required    # cb(err, serverid or undefined=not running anywhere)
        @get_state
            cb : (err, state) =>
                if err
                      opts.cb(err); return
                running_on = (server_id for server_id, s of state when s in ['running', 'starting', 'restarting', 'saving'])
                if running_on.length == 0
                    opts.cb()
                else
                    running_on.sort() # sort -- so any other client doing the same thing will kill the same other ones.
                    server_id = running_on[0]
                    @_stop_all(  (x for x,s in state when x != server_id)  )
                    @set_location_pref(server_id)   # remember in db so we'll prefer this host in future
                    opts.cb(undefined, server_id)

    _stop_all: (v) =>
        if v.length == 0
            return
        winston.debug("GlobalProject: repair by stopping on #{misc.to_json(v)}")
        for server_id in v
            @project
                server_id:server_id
                cb : (err, project) =>
                    if not err
                        project.stop(force:true)

    # get local copy of project on a specific host
    project: (opts) =>
        opts = defaults opts,
            server_id : required
            cb        : required
        @global_client.storage_server
            server_id : opts.server_id
            cb        : (err, s) =>
                if err
                    opts.cb(err)
                else
                    s.project   # this is cached
                        project_id : @project_id
                        cb         : opts.cb

    set_last_save: (opts) =>
        opts = defaults opts,
            last_save : required    # map  {server_id:timestamp, ...}
            bup_repo_size_kb : undefined  # if given, should be int
            cb        : undefined
        async.series([
            (cb) =>
                s = "UPDATE projects SET bup_last_save[?]=? WHERE project_id=?"
                f = (server_id, cb) =>
                    @database.cql(s, [server_id, opts.last_save[server_id], @project_id], cb)
                async.map(misc.keys(opts.last_save), f, cb)
            (cb) =>
                if opts.bup_repo_size_kb?
                    @database.update
                        table   : "projects"
                        set     : {bup_repo_size_kb : opts.bup_repo_size_kb}
                        where   : {project_id : @project_id}
                        cb      : cb
                else
                    cb()
        ], (err) -> opts.cb?(err))


    get_last_save: (opts) =>
        opts = defaults opts,
            cb : required
        @database.select
            table : 'projects'
            where : {project_id:@project_id}
            columns : ['bup_last_save']
            cb      : (err, result) =>
                if err
                    opts.cb(err)
                else
                    if result.length == 0 or not result[0][0]?
                        last_save = {}
                    else
                        last_save = result[0][0]
                    opts.cb(undefined, last_save)

    get_hosts: (opts) =>
        opts = defaults opts,
            cb : required
        hosts = []
        dbg = (m) -> winston.debug("GlobalProject.get_hosts(#{@project_id}): #{m}")
        async.series([
            (cb) =>
                dbg("get last save info from database...")
                @database.select
                    table : 'projects'
                    where : {project_id:@project_id}
                    columns : ['bup_last_save']
                    cb      : (err, r) =>
                        if err or not r? or r.length == 0
                            cb(err)
                        else
                            if r?[0]?
                                hosts = misc.keys(r[0])
                            cb()
            (cb) =>
                dbg("hosts=#{misc.to_json(hosts)}; ensure that we have (at least) one host from each data center")
                servers = @global_client.servers
                last_save = {}
                now = cassandra.now()
                for dc, servers_in_dc of servers.by_dc
                    have_one = false
                    for h in hosts
                        if servers_in_dc[h]?
                            have_one = true
                            break
                    if not have_one
                        h = misc.random_choice(misc.keys(servers_in_dc))
                        hosts.push(h)
                        last_save[h] = now # brand new, so nothing to save yet
                if last_save.length > 0
                    @set_last_save
                        last_save : last_save
                        cb        : cb
                else
                    cb()
        ], (err) => opts.cb(undefined, hosts))


    # determine the global state by querying *all servers*
    # guaranteed to return length > 0
    get_state: (opts) =>
        opts = defaults opts,
            timeout : 7
            cb      : required
        dbg = (m) -> winston.info("get_state: #{m}")
        dbg()
        servers = undefined
        @state = {}
        async.series([
            (cb) =>
                dbg("lookup the servers that host this project")
                @get_hosts
                    cb : (err, hosts) =>
                        if err
                            cb(err)
                        else
                            servers = hosts
                            dbg("servers=#{misc.to_json(servers)}")
                            cb()
            (cb) =>
                dbg("query each server for the project's state there")
                f = (server_id, cb) =>
                    dbg("query #{server_id} for state")
                    project = undefined
                    async.series([
                        (cb) =>
                            @project
                                server_id : server_id
                                cb        : (err, p) =>
                                    if err
                                        dbg("failed to get project on server #{server_id} -- #{err}")
                                    project = p
                                    cb(err)
                        (cb) =>
                            project.get_state
                                timeout : opts.timeout
                                cb : (err, s) =>
                                    if err
                                        dbg("error getting state on #{server_id} -- #{err}")
                                        s = 'error'
                                    @state[server_id] = s
                                    cb()
                    ], cb)

                async.map(servers, f, cb)

        ], (err) => opts.cb?(err, @state)
        )



global_client_cache=undefined

exports.global_client = (opts) ->
    opts = defaults opts,
        database           : undefined
        cb                 : required
    C = global_client_cache
    if C?
        opts.cb(undefined, C)
    else
        global_client_cache = new GlobalClient
            database : opts.database
            cb       : opts.cb


class GlobalClient
    constructor: (opts) ->
        opts = defaults opts,
            database : undefined   # connection to cassandra database
            cb       : required   # cb(err, @) -- called when initialized

        @_project_cache = {}

        async.series([
            (cb) =>
                if opts.database?
                    @database = opts.database
                    cb()
                else
                    fs.readFile "#{process.cwd()}/data/secrets/cassandra/hub", (err, password) =>
                        if err
                            cb(err)
                        else
                            if process.env.USER=='wstein'
                                hosts = ['localhost']
                            else
                                v = program.address.split('.')
                                a = parseInt(v[1]); b = parseInt(v[3])
                                if a == 1 and b>=1 and b<=7
                                    hosts = ("10.1.#{i}.1" for i in [1..7]).join(',')
                                else if a == 1 and b>=10 and b<=21
                                    hosts = ("10.1.#{i}.1" for i in [10..21]).join(',')
                                else if a == 3
                                    # TODO -- change this as soon as we get a DB spun up at Google...
                                    hosts = ("10.1.#{i}.1" for i in [10..21]).join(',')
                            @database = new cassandra.Salvus
                                hosts       : hosts
                                keyspace    : if process.env.USER=='wstein' then 'test' else 'salvus'
                                username    : if process.env.USER=='wstein' then 'salvus' else 'hub'
                                consistency : 2
                                password    : password.toString().trim()
                                cb          : cb
            (cb) =>
                @_update(cb)
        ], (err) =>
            if not err
                setInterval(@_update, 1000*STORAGE_SERVERS_UPDATE_INTERVAL_S)  # update regularly
                opts.cb(undefined, @)
            else
                opts.cb(err, @)
        )

    get_project: (project_id) =>
        P = @_project_cache[project_id]
        if not P?
            P = @_project_cache[project_id] = new GlobalProject(project_id, @)
        return P

    _update: (cb) =>
        dbg = (m) -> winston.debug("GlobalClient._update: #{m}")
        dbg("querying for available storage servers...")
        @database.select
            table     : 'storage_servers'
            columns   : ['server_id', 'host', 'port', 'dc', 'health', 'secret', 'vnodes']
            objectify : true
            where     : {dummy:true}
            cb        : (err, results) =>
                #dbg("got results; now initializing hashrings")
                if err
                    cb?(err); return
                # parse result
                @servers = {by_dc:{}, by_id:{}, by_host:{}}
                x = {}
                max_dc = 0
                for r in results
                    max_dc = Math.max(max_dc, r.dc)
                    r.host = cassandra.inet_to_str(r.host)  # parse inet datatype
                    @servers.by_id[r.server_id] = r
                    if not @servers.by_dc[r.dc]?
                        @servers.by_dc[r.dc] = {}
                    @servers.by_dc[r.dc][r.server_id] = r
                    @servers.by_host[r.host] = r
                cb?()

    push_servers_files: (opts) =>
        opts = defaults opts,
            timeout : 30           # timeout if scp fails after this much time -- will happen if a server down or stale...
            cb      : undefined    # cb(err)
        console.log("starting...")
        dbg = (m) -> winston.info("push_servers_files: #{m}")
        dbg('starting... logged')
        errors = {}
        file = "#{DATA}/bup_servers"
        async.series([
            (cb) =>
                dbg("updating")
                @_update(cb)
            (cb) =>
                dbg("writing file")
                # @servers = {server_id:{host:'ip address', vnodes:128, dc:2}, ...}
                servers_conf = {}
                for server_id, x of @servers
                    servers_conf[server_id] = {host:x.host, vnodes:x.vnodes, dc:x.dc}
                fs.writeFile(file, misc.to_json(servers_conf), cb)
            (cb) =>
                f = (server_id, c) =>
                    host = @servers[server_id].host
                    dbg("copying #{file} to #{host}...")
                    misc_node.execute_code
                        command : "scp"
                        timeout : opts.timeout
                        path    : process.cwd()
                        args    : ['-o', 'StrictHostKeyChecking=no', file, "#{host}:#{program.servers_file}"]
                        cb      : (err) =>
                            if err
                                errors[server_id] = err
                            c()
                async.map misc.keys(@servers), f, (err) =>
                    if misc.len(errors) == 0
                        opts.cb?()
                    else
                        opts.cb?(errors)
        ], (err) =>
            dbg("done!")
            if err
                dbg(err)
                opts.cb?(err)
            else
                opts.cb?()
        )

    register_server: (opts) =>
        opts = defaults opts,
            host   : required
            dc     : 0           # 0, 1, 2, .etc.
            vnodes : 128
            timeout: 30
            cb     : undefined
        dbg = (m) -> winston.debug("GlobalClient.add_storage_server(#{opts.host}, #{opts.dc},#{opts.vnodes}): #{m}")
        dbg("adding storage server to the database by grabbing server_id files, etc.")
        get_file = (path, cb) =>
            dbg("get_file: #{path}")
            misc_node.execute_code
                command : "ssh"
                path    : process.cwd()
                timeout : opts.timeout
                args    : ['-o', 'StrictHostKeyChecking=no', opts.host, "cat #{path}"]
                cb      : (err, output) =>
                    if err
                        cb(err)
                    else if output?.stderr and output.stderr.indexOf('No such file or directory') != -1
                        cb(output.stderr)
                    else
                        cb(undefined, output.stdout)

        set = {host:opts.host, dc:opts.dc, vnodes:opts.vnodes, port:undefined, secret:undefined}
        where = {server_id:undefined, dummy:true}

        async.series([
            (cb) =>
                get_file program.portfile, (err, port) =>
                    set.port = parseInt(port); cb(err)
            (cb) =>
                get_file program.server_id_file, (err, server_id) =>
                    where.server_id = server_id
                    cb(err)
            (cb) =>
                get_file program.secret_file, (err, secret) =>
                    set.secret = secret
                    cb(err)
            (cb) =>
                dbg("update database")
                @database.update
                    table : 'storage_servers'
                    set   : set
                    where : where
                    cb    : cb
        ], (err) => opts.cb?(err))


    score_servers: (opts) =>
        opts = defaults opts,
            healthy   : undefined     # list of server_ids we have found to be healthy
            unhealthy : undefined     # list of server_ids we have found to be unhealthy
            cb        : undefined     # cb(err)
        s = []
        if opts.healthy?
            s = s.concat(opts.healthy)
        else
            opts.healthy = []
        if opts.unhealthy?
            s = s.concat(opts.unhealthy)
        else
            opts.unhealthy = []
        if s.length == 0
            opts.cb?(); return
        @database.select
            table     : 'storage_servers'
            columns   : ['server_id', 'health']
            objectify : true
            where     : {dummy:true, server_id:{'in':s}}
            cb        : (err, results) =>
                f = (result, cb) =>
                    # TODO: replace formula before by what's done in gossip/cassandra, which is provably sensible.
                    # There is definitely a potential for "race conditions" below, but it doesn't matter -- it is just health.
                    if result.server_id in opts.healthy
                        if not result.health?
                            result.health = 1
                        else
                            result.health = (result.health + 1)/2.0
                    else if result.server_id in opts.unhealthy
                        if not result.health?
                            result.health = 0
                        else
                            result.health = (result.health + 0)/2.0
                    @database.update
                        table : 'storage_servers'
                        set   : {health:result.health}
                        where : {dummy:true, server_id:result.server_id}
                        cb    : cb
                async.map(results, f, (err) => opts.cb?(err))

    storage_server: (opts) =>
        opts = defaults opts,
            server_id : required
            cb        : required
        if not @servers[opts.server_id]?
            opts.cb("server #{opts.server_id} unknown")
            return
        s = @servers[opts.server_id]
        if not s.host?
            opts.cb("no hostname known for #{opts.server_id}")
            return
        if not s.port?
            opts.cb("no port known for #{opts.server_id}")
            return
        if not s.secret?
            opts.cb("no secret token known for #{opts.server_id}")
            return
        opts.cb(undefined, storage_server_client(host:s.host, port:s.port, secret:s.secret, server_id:opts.server_id))

    project_location: (opts) =>
        opts = defaults opts,
            project_id : required
            cb         : required
        winston.debug("project_location(#{opts.project_id}): get current bup project location from database")
        @database.select_one
            table     : 'projects'
            where     : {project_id : opts.project_id}
            columns   : ['bup_location']
            objectify : false
            cb        : (err, result) =>
                if err
                    opts.cb(err)
                else
                    opts.cb(undefined, result[0])


    project: (opts) =>
        opts = defaults opts,
            project_id : required
            server_id  : undefined  # if undefined gets best working client pre-started; if defined connect if possible but don't start anything
            prefer     : undefined  # if given, should be array of prefered servers -- only used if project isn't already opened somewhere
            prefer_not : undefined  # array of servers we prefer not to use
            cb         : required   # cb(err, Project client connection on some host)
        dbg = (m) => winston.debug("GlobalClient.project(#{opts.project_id}): #{m}")
        dbg()

        if opts.server_id?
            dbg("open on a specified client")
            @storage_server
                server_id : opts.server_id
                cb        : (err, s) =>
                    if err
                        opts.cb(err); return
                    s.project
                        project_id : opts.project_id
                        cb         : opts.cb
            return

        bup_location = undefined
        project      = undefined
        works        = undefined
        status       = undefined
        errors       = {}
        async.series([
            (cb) =>
                @project_location
                    project_id : opts.project_id
                    cb         : (err, result) =>
                        bup_location = result
                        cb(err)
            (cb) =>
                if not bup_location?
                    dbg("no current location")
                    cb()
                else
                    dbg("there is current location (=#{bup_location}) and project is working at current location, use it")
                    @project
                        project_id : opts.project_id
                        server_id  : bup_location
                        cb         : (err, _project) =>
                            if not err
                                project = _project
                            cb()
            (cb) =>
                if not project?
                    dbg("no accessible project currently started...")
                    cb()
                else
                    dbg("if project will start at current location, use it")
                    project.works
                        cb: (err, _works) =>
                            if err
                                project = undefined
                                cb()
                            else
                                works = _works
                                cb()
            (cb) =>
                if works
                    cb(); return
                dbg("try harder: get list of all locations (except current) and ask in parallel about status of each")
                @project_status
                    project_id  : opts.project_id
                    cb          : (err, _status) =>
                        if err
                            cb(err)
                        else
                            status = _status
                            cb()
            (cb) =>
                if works
                    cb(); return
                dbg("until success, choose one that responded with best status and try to start there")
                # remove those with error getting status
                for x in status
                    if x.error?
                        errors[x.replica_id] = x.error
                v = (x.replica_id for x in status when not x.error? and x.status?.bup in ['working', 'uninitialized'])

                prefer = opts.prefer; prefer_not = opts.prefer_not
                if prefer? or prefer_not?
                    # The following ugly code is basically "status=v" but with some re-ordering based on preference.
                    # put prefer servers at front of list; prefer_not servers at back; everything else in between
                    status = []
                    if prefer?
                        for s in prefer
                            if s in v
                                status.push(s)
                    if not prefer_not?
                        prefer_not = []
                    for s in v
                        if s not in status and s not in prefer_not
                            status.push(s)
                    for s in prefer_not
                        if s in v
                            status.push(s)
                else
                    status = v


                f = (replica_id, cb) =>
                    if works
                        cb(); return
                    @project
                        project_id : opts.project_id
                        server_id  : replica_id
                        cb         : (err, _project) =>
                            if err
                                dbg("error trying to open project on #{replica_id} -- #{err}")
                                cb(); return # skip to next
                            _project.restart
                                cb : (err) =>
                                    if not err
                                        project = _project
                                        bup_location = replica_id
                                        works = true
                                    else
                                        errors[replica_id] = err
                                        dbg("error trying to start project on #{replica_id} -- #{err}")
                                    cb()
                async.mapSeries(status, f, (err) => cb())
            (cb) =>
                if works and project? and bup_location?
                    dbg("succeeded at opening the project at #{bup_location} -- now recording this in DB")
                    @database.update
                        table : 'projects'
                        where : {project_id   : opts.project_id}
                        set   : {bup_location : bup_location}
                        cb    : cb
                else
                    cb("unable to open project anywhere")
        ], (err) =>
            if err
                opts.cb("unable to deploy project anywhere -- #{err}, #{misc.to_json(errors)}")
            else
                opts.cb(undefined, project)
        )

    project_status: (opts) =>
        opts = defaults opts,
            project_id         : required
            timeout            : 20   # seconds
            cb                 : required    # cb(err, sorted list of status objects)
        status = []
        f = (replica, cb) =>
            t = {replica_id:replica}
            status.push(t)
            @project
                project_id : opts.project_id
                server_id  : replica
                cb         : (err, project) =>
                    if err
                        t.error = err
                        cb()
                    else
                        project.status
                            timeout : opts.timeout
                            cb      : (err, _status) =>
                                if err
                                    @score_servers(unhealthy : [replica])
                                    t.error = err
                                    cb()
                                else
                                    @score_servers(healthy   : [replica])
                                    t.status = _status
                                    cb()
        hosts = undefined
        async.series([
            (cb) =>
                @get_hosts
                    cb : (err, h) =>
                        hosts = h; cb(err)
            (cb) =>
                async.map hosts, f, (err) =>
                    status.sort (a,b) =>
                        if a.error? and b.error?
                            return 0  # doesn't matter -- both are broken/useless
                        if a.error? and not b.error
                            # b is better
                            return 1
                        if b.error? and not a.error?
                            # a is better
                            return -1
                        # sort of arbitrary -- mainly care about newest snapshot being newer = better = -1
                        if a.status.newest_snapshot?
                            if not b.status.newest_snapshot?
                                # a is better
                                return -1
                            else if a.status.newest_snapshot > b.status.newest_snapshot
                                # a is better
                                return -1
                            else if a.status.newest_snapshot < b.status.newest_snapshot
                                # b is better
                                return 1
                        else
                            if b.status.newest_snapshot?
                                # b is better
                                return 1
                        # Next compare health of server
                        health_a = @servers[a.replica_id]?.health
                        health_b = @servers[b.replica_id]?.health
                        if health_a? and health_b?
                            health_a = Math.round(3.8*health_a)
                            health_b = Math.round(3.8*health_b)
                            if health_a < health_b
                                # b is better
                                return 1
                            else if health_a > health_b
                                # a is better
                                return -1
                        # no error, so load must be defined
                        # smaller load is better -- later take into account free RAM, etc...
                        if a.status.load[0] < b.status.load[0]
                            return -1
                        else if a.status.load[0] > b.status.load[0]
                            return 1
                        return 0
                    cb()
            ], (err) =>
                opts.cb(err, status)
            )



###########################
## Client -- code below mainly sets up a connection to a given storage server
###########################


class Client
    constructor: (opts) ->
        opts = defaults opts,
            host      : required
            port      : required
            secret    : required
            server_id : required
            verbose   : required
        @host      = opts.host
        @port      = opts.port
        @secret    = opts.secret
        @verbose   = opts.verbose
        @server_id = opts.server_id

    dbg: (f, args, m) =>
        if @verbose
            winston.debug("storage Client(#{@host}:#{@port}).#{f}(#{misc.to_json(args)}): #{m}")

    connect: (cb) =>
        dbg = (m) => winston.debug("Storage client (#{@host}:#{@port}): #{m}")
        dbg()
        async.series([
            (cb) =>
                dbg("ensure secret_token")
                read_secret_token(cb)
            (cb) =>
                dbg("connect to locked socket")
                misc_node.connect_to_locked_socket
                    host    : @host
                    port    : @port
                    token   : @secret
                    timeout : 20
                    cb      : (err, socket) =>
                        if err
                            dbg("failed to connect: #{err}")
                            @socket = undefined
                            cb(err)
                        else
                            dbg("successfully connected")
                            @socket = socket
                            misc_node.enable_mesg(@socket)
                            cb()
        ], cb)


    mesg: (project_id, action, param) =>
        mesg = message.storage
            id         : uuid.v4()
            project_id : project_id
            action     : action
            param      : param
        return mesg

    call: (opts) =>
        opts = defaults opts,
            mesg    : required
            timeout : 60
            cb      : undefined
        async.series([
            (cb) =>
                if not @socket?
                    @connect (err) =>
                        if err
                            opts.cb?(err)
                            cb(err)
                        else
                            cb()
                else
                    cb()
            (cb) =>
                @_call(opts)
                cb()
        ])

    _call: (opts) =>
        opts = defaults opts,
            mesg    : required
            timeout : 300
            cb      : undefined
        @dbg("call", opts, "start call")
        @socket.write_mesg 'json', opts.mesg, (err) =>
            @dbg("call", opts, "got response from socket write mesg: #{err}")
            if err
                if not @socket?   # extra messages but socket already gone -- already being handled below
                    return
                if err == "socket not writable"
                    @socket = undefined
                    @dbg("call",opts,"socket closed: reconnect and try again...")
                    @connect (err) =>
                        if err
                            opts.cb?(err)
                        else
                            @call
                                mesg    : opts.mesg
                                timeout : opts.timeout
                                cb      : opts.cb
                else
                    opts.cb?(err)
            else
                @dbg("call",opts,"waiting to receive response")
                @socket.recv_mesg
                    type    : 'json'
                    id      : opts.mesg.id
                    timeout : opts.timeout
                    cb      : (mesg) =>
                        @dbg("call",opts,"got response -- #{misc.to_json(mesg)}")
                        mesg.project_id = opts.mesg.project_id
                        if mesg.event == 'error'
                            opts.cb?(mesg.error)
                        else
                            delete mesg.id
                            opts.cb?(undefined, mesg)

    action: (opts) =>
        opts = defaults opts,
            action     : required
            param      : undefined
            project_id : undefined   # a single project id
            project_ids: undefined   # or a list of project ids -- in which case, do the actions in parallel with limit at once
            timeout    : TIMEOUT     # different defaults depending on the action
            limit      : 3
            cb         : undefined

        errors = {}
        f = (project_id, cb) =>
            @call
                mesg    : @mesg(project_id, opts.action, opts.param)
                timeout : opts.timeout
                cb      : (err, result) =>
                    if err
                        errors[project_id] = err
                    cb(undefined, result)

        if opts.project_id?
            f(opts.project_id, (ignore, result) => opts.cb?(errors[opts.project_id], result))

        if opts.project_ids?
            async.mapLimit opts.project_ids, opts.limit, f, (ignore, results) =>
                if misc.len(errors) == 0
                    errors = undefined
                opts.cb?(errors, results)

    project: (opts) =>
        opts = defaults opts,
            project_id : required
            cb         : required
        client_project
            client     : @
            project_id : opts.project_id
            cb         : opts.cb

client_cache = {}

storage_server_client = (opts) ->
    opts = defaults opts,
        host      : required
        port      : required
        secret    : required
        server_id : required
        verbose   : true
    dbg = (m) -> winston.debug("storage_server_client(#{opts.host}:#{opts.port}): #{m}")
    dbg()
    key = opts.host + opts.port + opts.secret
    C = client_cache[key]
    if not C?
        C = client_cache[key] = new Client(host:opts.host, port:opts.port, secret: opts.secret, verbose:opts.verbose, server_id:opts.server_id)
    return C

# A client on a *particular* server
class ClientProject
    constructor: (@client, @project_id) ->
        @dbg("constructor",[],"")

    dbg: (f, args, m) =>
        winston.debug("storage ClientProject(#{@project_id}).#{f}(#{misc.to_json(args)}): #{m}")

    action: (opts) =>
        opts = defaults opts,
            action     : required
            param      : undefined
            timeout    : TIMEOUT
            cb         : undefined
        opts.project_id = @project_id
        @client.action(opts)

    start: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            cb         : undefined
        opts.action = 'start'
        @action(opts)

    # state is one of the following: stopped, starting, running, restarting, stopping, saving, error
    get_state: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            cb         : required  # cb(err, state)
        opts.action = 'get_state'
        cb = opts.cb
        opts.cb = (err, resp) =>
            cb(err, resp?.result)
        @action(opts)

    # extensive information about the project, e.g., port it is listening on, quota information, etc.
    status: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            cb         : required
        opts.action = 'status'
        cb = opts.cb
        opts.cb = (err, resp) =>
            cb(err, resp?.result)
        @action(opts)

    works: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            cb         : required   # cb(undefined, true if works)    -- never errors, since "not works=error"
        # using status for now -- may want to use something cheaper (?)
        works = false
        async.series([
            (cb) =>
                @status
                    timeout : opts.timeout
                    cb      : (err, status) =>
                        if err or not status?['local_hub.port']?
                            cb()
                        else
                            works = true
                            cb()
            (cb) =>
                if works
                    cb(); return
                @restart(cb : cb)
            (cb) =>
                if works
                    cb(); return
                @status
                    timeout : opts.timeout
                    cb      : (err, status) =>
                        if err or not status?['local_hub.port']?
                            cb()
                        else
                            works = true
                            cb()
        ], (err) =>
            if err or not works
                opts.cb(undefined, false)
            else
                opts.cb(undefined, true)
        )

    stop: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            force      : false
            cb         : undefined
        opts.action = 'stop'
        if opts.force
            opts.param = 'force'
            delete opts.force
        @action(opts)


    restart: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            cb         : undefined
        opts.action = 'restart'
        @action(opts)

    save: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            targets    : undefined    # undefined or a list of ip addresses
            cb         : undefined
        opts.action = 'save'
        if opts.targets?
            opts.param = "--targets=#{opts.targets.join(',')}"
        delete opts.targets
        @action(opts)

    init: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            cb         : undefined
        opts.action = 'init'
        @action(opts)

    snapshots: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            cb         : required
        opts.action = 'snapshots'
        cb = opts.cb
        opts.cb = (err, resp) =>
            cb(err, resp?.result)
        @action(opts)

    settings: (opts) =>
        opts = defaults opts,
            timeout    : TIMEOUT
            memory     : undefined
            cpu_shares : undefined
            cores      : undefined
            disk       : undefined
            scratch    : undefined
            inode      : undefined
            mintime    : undefined
            login_shell: undefined
            cb         : undefined

        param = []
        for x in ['memory', 'cpu_shares', 'cores', 'disk', 'scratch', 'inode', 'mintime', 'login_shell']
            if opts[x]?
                param.push("--#{x}")
                param.push(opts[x])
        @action
            timeout : opts.timeout
            action  : 'settings'
            param   : param
            cb      : opts.cb

    sync: (opts) =>
        opts = defaults opts,
            timeout            : TIMEOUT
            destructive        : false
            snapshots          : true   # whether to sync snapshots -- if not given, only syncs live files
            cb                 : undefined
        params = []
        if opts.snapshots
            params.push('--snapshots')
        if opts.destructive
            params.push('--destructive')
        @action
            action  : 'sync'
            param   : params
            timeout : TIMEOUT
            cb      : opts.cb


client_project_cache = {}

client_project = (opts) ->
    opts = defaults opts,
        client     : required
        project_id : required
        cb         : required
    if not misc.is_valid_uuid_string(opts.project_id)
        opts.cb("invalid project id")
        return
    key = "#{opts.client.host}-#{opts.client.port}-#{opts.project_id}"
    P = client_project_cache[key]
    if not P?
        P = client_project_cache[key] = new ClientProject(opts.client, opts.project_id)
    opts.cb(undefined, P)


###########################
## Command line interface
###########################

program.usage('[start/stop/restart/status] [options]')

    .option('--pidfile [string]', 'store pid in this file', String, "#{CONF}/bup_server.pid")
    .option('--logfile [string]', 'write log to this file', String, "#{CONF}/bup_server.log")
    .option('--portfile [string]', 'write port number to this file', String, "#{CONF}/bup_server.port")
    .option('--server_id_file [string]', 'file in which server_id is stored', String, "#{CONF}/bup_server_id")
    .option('--servers_file [string]', 'contains JSON mapping {uuid:hostname,...} for all servers', String, "#{CONF}/bup_servers")
    .option('--secret_file [string]', 'write secret token to this file', String, "#{CONF}/bup_server.secret")

    .option('--debug [string]', 'logging debug level (default: "" -- no debugging output)', String, 'debug')
    .option('--replication [string]', 'replication factor (default: 2)', String, '2')

    .option('--port [integer]', "port to listen on (default: assigned by OS)", String, 0)
    .option('--address [string]', 'address to listen on (default: the tinc network or 127.0.0.1 if no tinc)', String, '')

    .parse(process.argv)

program.port = parseInt(program.port)

if not program.address
    program.address = require('os').networkInterfaces().tun0?[0].address
    if not program.address
        program.address = require('os').networkInterfaces().eth1?[0].address  # my laptop vm...
    if not program.address  # useless
        program.address = '127.0.0.1'

main = () ->
    if program.debug
        winston.remove(winston.transports.Console)
        winston.add(winston.transports.Console, level: program.debug)

    winston.debug "Running as a Daemon"
    # run as a server/daemon (otherwise, is being imported as a library)
    process.addListener "uncaughtException", (err) ->
        winston.error("Uncaught exception: #{err}")
    daemon({pidFile:program.pidfile, outFile:program.logfile, errFile:program.logfile}, start_server)

if program._name == 'bup_server.js'
    main()


