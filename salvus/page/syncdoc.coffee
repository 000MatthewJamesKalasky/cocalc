###
Synchronized Documents

A merge map, with the arrows pointing upstream:


     [client]s.. ---> [hub] ---> [local hub] <--- [hub] <--- [client] <--- YOU ARE HERE
                      /|\             |
     [client]-----------             \|/
                              [a file on disk]

The Global Architecture of Synchronized Documents:

Imagine say 1000 clients divided evenly amongst 10 hubs (so 100 clients per hub).
There is only 1 local hub, since it is directly linked to an on-disk file.

The global hubs manage their 100 clients each, merging together sync's, and sending them
(as a batch) to the local hub.  Broadcast messages go from a client, to its hub, then back
to the other 99 clients, then on to the local hub, out to 9 other global hubs, and off to
their 900 clients in parallel.

###

log = (s) -> console.log(s)

diffsync = require('diffsync')

misc     = require('misc')
{defaults, required} = misc

message  = require('message')

{salvus_client} = require('salvus_client')
{alert_message} = require('alerts')

{IS_MOBILE} = require("feature")

async = require('async')

templates           = $("#salvus-editor-templates")
cell_start_template = templates.find(".sagews-input")
output_template     = templates.find(".sagews-output")

salvus_threejs = require("salvus_threejs")

account = require('account')

# Return true if there are currently unsynchronized changes, e.g., due to the network
# connection being down, or cloud.sagemath not working, or a bug.
exports.unsynced_docs = () ->
    return $(".salvus-editor-codemirror-not-synced:visible").length > 0

class DiffSyncDoc
    # Define exactly one of cm or string.
    #     cm     = a live codemirror editor
    #     string = a string
    constructor: (opts) ->
        @opts = defaults opts,
            cm     : undefined
            string : undefined
        if not ((opts.cm? and not opts.string?) or (opts.string? and not opts.cm?))
            console.log("BUG -- exactly one of opts.cm and opts.string must be defined!")

    copy: () =>
        # always degrades to a string
        if @opts.cm?
            return new DiffSyncDoc(string:@opts.cm.getValue())
        else
            return new DiffSyncDoc(string:@opts.string)

    string: () =>
        if @opts.string?
            return @opts.string
        else
            return @opts.cm.getValue()  # WARNING: this is *not* cached.

    diff: (v1) =>
        # TODO: when either is a codemirror object, can use knowledge of where/if
        # there were edits as an optimization
        return diffsync.dmp.patch_make(@string(), v1.string())

    patch: (p) =>
        return new DiffSyncDoc(string: diffsync.dmp.patch_apply(p, @string())[0])

    checksum: () =>
        return @string().length

    patch_in_place: (p) =>
        if @opts.string
            console.log("patching string in place -- should never happen")
            @opts.string = diffsync.dmp.patch_apply(p, @string())[0]
        else
            cm = @opts.cm
            cm.setOption('readOnly', true)
            try
                s = @string()
                x = diffsync.dmp.patch_apply(p, s)
                new_value = x[0]

                next_pos = (val, pos) ->
                    # This functions answers the question:
                    # If you were to insert the string val at the CodeMirror position pos
                    # in a codemirror document, at what position (in codemirror) would
                    # the inserted string end at?
                    number_of_newlines = (val.match(/\n/g)||[]).length
                    if number_of_newlines == 0
                        return {line:pos.line, ch:pos.ch+val.length}
                    else
                        return {line:pos.line+number_of_newlines, ch:(val.length - val.lastIndexOf('\n')-1)}

                pos = {line:0, ch:0}  # start at the beginning
                diff = diffsync.dmp.diff_main(s, new_value)
                for chunk in diff
                    #console.log(chunk)
                    op  = chunk[0]  # 0 = stay same; -1 = delete; +1 = add
                    val = chunk[1] # the actual text to leave same, delete, or add
                    pos1 = next_pos(val, pos)
                    switch op
                        when 0 # stay the same
                            # Move our pos pointer to the next position
                            pos = pos1
                            #console.log("skipping to ", pos1)
                        when -1 # delete
                            # Delete until where val ends; don't change pos pointer.
                            cm.replaceRange("", pos, pos1)
                            #console.log("deleting from ", pos, " to ", pos1)
                        when +1 # insert
                            # Insert the new text right here.
                            cm.replaceRange(val, pos)
                            #console.log("inserted new text at ", pos)
                            # Move our pointer to just beyond the text we just inserted.
                            pos = pos1
            catch e
                console.log("BUG in patch_in_place")
            cm.setOption('readOnly', false)



codemirror_diffsync_client = (cm_session, content) ->
    # This happens on initialization and reconnect.  On reconnect, we could be more
    # clever regarding restoring the cursor and the scroll location.
    cm_session.codemirror._cm_session_cursor_before_reset = cm_session.codemirror.getCursor()
    cm_session.codemirror.setValueNoJump(content)

    return new diffsync.CustomDiffSync
        doc            : new DiffSyncDoc(cm:cm_session.codemirror)
        copy           : (s) -> s.copy()
        diff           : (v0,v1) -> v0.diff(v1)
        patch          : (d, v0) -> v0.patch(d)
        checksum       : (s) -> s.checksum()
        patch_in_place : (p, v0) -> v0.patch_in_place(p)

# The DiffSyncHub class represents a global hub viewed as a
# remote server for this client.
class DiffSyncHub
    constructor: (@cm_session) ->

    connect: (remote) =>
        @remote = remote

    recv_edits: (edit_stack, last_version_ack, cb) =>
        @cm_session.call
            message : message.codemirror_diffsync(edit_stack:edit_stack, last_version_ack:last_version_ack)
            timeout : 30
            cb      : (err, mesg) =>
                if err
                    cb(err)
                else if mesg.event != 'codemirror_diffsync'
                    # various error conditions, e.g., reconnect, etc.
                    cb(mesg.event)
                else
                    @remote.recv_edits(mesg.edit_stack, mesg.last_version_ack, cb)

{EventEmitter} = require('events')

class AbstractSynchronizedDoc extends EventEmitter
    constructor: (opts) ->
        @opts = defaults opts,
            project_id : required
            filename   : required
            sync_interval : 1000    # no matter what, we won't send sync messages back to the server more frequently than this (in ms)
            cb         : required   # cb(err) once doc has connected to hub first time and got session info; will in fact keep trying until success

        @project_id = @opts.project_id
        @filename   = @opts.filename

        @connect    = misc.retry_until_success_wrapper(f:@_connect)#, logname:'connect')
        @sync       = misc.retry_until_success_wrapper(f:@_sync, min_interval:@opts.sync_interval)#, logname:'sync')
        @save       = misc.retry_until_success_wrapper(f:@_save)#, logname:'save')

        @connect (err) =>
            opts.cb(err, @)

    _connect: (cb) =>
        throw "define _connect in derived class"

    _add_listeners: () =>
        salvus_client.on 'codemirror_diffsync_ready', @__diffsync_ready
        salvus_client.on 'codemirror_bcast', @__receive_broadcast
        salvus_client.on 'signed_in', @__reconnect

    _remove_listeners: () =>
        salvus_client.removeListener 'codemirror_diffsync_ready', @__diffsync_ready
        salvus_client.removeListener 'codemirror_bcast', @__receive_broadcast
        salvus_client.removeListener 'signed_in', @__reconnect

    __diffsync_ready: (mesg) =>
        if mesg.session_uuid == @session_uuid
            @sync()

    __receive_broadcast: (mesg) =>
        if mesg.session_uuid == @session_uuid
            if mesg.mesg.event == 'update_session_uuid'
                # This just doesn't work yet -- not really implemented in the hub -- so we force
                # a full reconnect, which is safe.
                #@session_uuid = mesg.mesg.new_session_uuid
                @connect()

    __reconnect: () =>
        # The main websocket to the remote server died then came back, so we
        # setup a new syncdoc session with the remote hub.  This will work fine,
        # even if we connect to a different hub.
        @connect (err) =>

    _apply_patch_to_live: (patch) =>
        @dsync_client._apply_edits_to_live(patch)

    # @live(): the current live version of this document as a string, or
    # @live(s): set the live version
    live: (s) =>
        if s?
            @dsync_client.live = s
        else
            return @dsync_client?.live

    # "sync(cb)": keep trying to synchronize until success; then do cb()
    # _sync(cb) -- try once to sync; on any error cb(err).
    _sync: (cb) =>
        @_presync?()
        snapshot = @live()
        @dsync_client.push_edits (err) =>
            if err
                if err.indexOf('retry') != -1
                    # This is normal -- it's because the diffsync algorithm only allows sync with
                    # one client (and upstream) at a time.
                    cb?(err)
                else  # all other errors should reconnect first.
                    @connect () =>
                        cb?(err)
            else
                s = snapshot
                if s.copy?
                    s = s.copy()
                @_last_sync = s    # What was the last successful sync with upstream.
                @emit('sync')
                cb?()

    # save(cb): write out file to disk retrying until success.
    # _save(cb): try to sync then write to disk; if anything goes wrong, cb(err).
    _save: (cb) =>
        if not @dsync_client?
            cb("must be connected before saving"); return
        @sync (err) =>
            if err
                cb(err); return
            @call
                message : message.codemirror_write_to_disk()
                timeout : 10
                cb      : (err, resp) ->
                    if err or resp.event != 'success'
                        cb(true)
                    else
                        cb()

    call: (opts) =>
        opts = defaults opts,
            message     : required
            timeout     : 30
            cb          : undefined
        opts.message.session_uuid = @session_uuid
        salvus_client.call(opts)


class SynchronizedString extends AbstractSynchronizedDoc
    # "connect(cb)": Connect to the given server; will retry until it succeeds.
    # _connect(cb): Try once to connect and on any error, cb(err).
    _connect: (cb) =>
        @_remove_listeners()
        delete @session_uuid
        @call
            timeout : 30     # a reasonable amount of time, since file could be *large*
            message : message.codemirror_get_session
                path         : @filename
                project_id   : @project_id
            cb      : (err, resp) =>
                if resp.event == 'error'
                    err = resp.error
                if err
                    cb?(err); return
                @session_uuid = resp.session_uuid

                if @_last_sync?
                    # We have sync'd before.
                    patch = @dsync_client._compute_edits(@_last_sync, @live())

                @dsync_client = new diffsync.DiffSync(doc:resp.content)

                if @_last_sync?
                    # applying missed patches to the new upstream version that we just got from the hub.
                    @_apply_patch_to_live(patch)
                else
                    # This initialiation is the first.
                    @_last_sync   = resp.content

                @dsync_server = new DiffSyncHub(@)
                @dsync_client.connect(@dsync_server)
                @dsync_server.connect(@dsync_client)
                @_add_listeners()
                @emit('connect')

                cb?()


synchronized_string = (opts) ->
    new SynchronizedString(opts)

exports.synchronized_string = synchronized_string


class SynchronizedDocument extends AbstractSynchronizedDoc
    constructor: (@editor, opts, cb) ->  # if given, cb will be called when done initializing.
        @opts = defaults opts,
            cursor_interval : 1000
            sync_interval   : 750   # never send sync messages up stream more often than this

        @connect    = misc.retry_until_success_wrapper(f:@_connect)#, logname:'connect')
        @sync       = misc.retry_until_success_wrapper(f:@_sync, min_interval:@opts.sync_interval)#, logname:'sync')
        @save       = misc.retry_until_success_wrapper(f:@_save)#, logname:'save')

        @filename    = @editor.filename
        @editor.save = @save
        @codemirror  = @editor.codemirror
        if misc.filename_extension(@filename) == "sagews"
            @editor._set("Loading and connecting to Sage session...  (if this fails, try restarting your Worksheet server in settings)")
        else
            @editor._set("Loading...")
        @codemirror.setOption('readOnly', true)
        @element     = @editor.element

        @init_cursorActivity_event()

        synchronized_string
            project_id    : @editor.project_id
            filename      : misc.meta_file(@filename, 'chat')
            sync_interval : 1000
            cb            : (err, chat_session) =>
                if not err  # err actually can't happen, since we retry until success...
                    @chat_session = chat_session
                    @init_chat()

        @on 'sync', () =>
            @ui_synced(true)

        @connect (err) =>
            if err
                bootbox.alert "<h3>Unable to open '#{@filename}'</h3> - #{err}", () =>
                    @editor.editor.close(@filename)
            else
                @ui_synced(false)
                @editor.init_autosave()
                @sync()
                @codemirror.on 'change', (instance, changeObj) =>
                    #console.log("change #{misc.to_json(changeObj)}")
                    if changeObj.origin?
                        if changeObj.origin == 'undo'
                            @on_undo(instance, changeObj)
                        if changeObj.origin == 'redo'
                            @on_redo(instance, changeObj)
                        if changeObj.origin != 'setValue'
                            @ui_synced(false)
                            @sync()
            # Done initializing and have got content.
            cb?()

    _sync: (cb) =>
        if not @dsync_client?
            cb("not initialized")
            return
        super(cb)

    _connect: (cb) =>
        @_remove_listeners()
        delete @session_uuid
        @ui_loading()
        @call
            timeout : 30     # a reasonable amount of time, since file could be *large*
            message : message.codemirror_get_session
                path         : @filename
                project_id   : @editor.project_id
            cb      : (err, resp) =>
                @ui_loaded()
                if resp.event == 'error'
                    err = resp.error
                if err
                    cb(err); return

                @session_uuid = resp.session_uuid

                if @_last_sync?
                    # We have sync'd before.
                    synced_before = true
                    patch = @dsync_client._compute_edits(@_last_sync, @live())
                else
                    # This initialiation is the first sync.
                    @_last_sync   = DiffSyncDoc(string:resp.content)
                    synced_before = false
                    @codemirror.setOption('readOnly', false)
                    @editor._set(resp.content)
                    @codemirror.clearHistory()  # so undo history doesn't start with "empty document"

                @dsync_client = codemirror_diffsync_client(@, resp.content)

                if synced_before
                    # applying missed patches to the new upstream version that we just got from the hub.
                    @_apply_patch_to_live(patch)
                    @emit 'sync'

                @dsync_server = new DiffSyncHub(@)
                @dsync_client.connect(@dsync_server)
                @dsync_server.connect(@dsync_client)
                @_add_listeners()
                @editor.save_button.addClass('disabled')   # TODO: start with no unsaved changes -- not tech. correct!!

                @emit 'connect'    # successful connection

                cb()

    ui_loading: () =>
        @element.find(".salvus-editor-codemirror-loading").show()

    ui_loaded: () =>
        @element.find(".salvus-editor-codemirror-loading").hide()


    on_undo: (instance, changeObj) =>
        # do nothing in base class

    on_redo: (instance, changeObj) =>
        # do nothing in base class

    _add_listeners: () =>
        salvus_client.on 'codemirror_diffsync_ready', @_diffsync_ready
        salvus_client.on 'codemirror_bcast', @_receive_broadcast
        salvus_client.on 'signed_in', @__reconnect


    _remove_listeners: () =>
        salvus_client.removeListener 'codemirror_diffsync_ready', @_diffsync_ready
        salvus_client.removeListener 'codemirror_bcast', @_receive_broadcast
        salvus_client.removeListener 'signed_in', @__reconnect

    __reconnect: () =>
        # The main websocket to the remote server died then came back, so we
        # setup a new syncdoc session with the remote hub.  This will work fine,
        # even if we connect to a different hub.
        @connect (err) =>

    disconnect_from_session: (cb) =>
        @_remove_listeners()
        salvus_client.call
            timeout : 10
            message : message.codemirror_disconnect(session_uuid : @session_uuid)
            cb      : cb

        # store pref in localStorage to not auto-open this file next time
        @editor.local_storage('auto_open', false)

    execute_code: (opts) =>
        opts = defaults opts,
            code     : required
            data     : undefined
            preparse : true
            cb       : undefined
        uuid = misc.uuid()
        salvus_client.send(
            message.codemirror_execute_code
                id   : uuid
                code : opts.code
                data : opts.data
                preparse : opts.preparse
                session_uuid : @session_uuid
        )
        if opts.cb?
            salvus_client.execute_callbacks[uuid] = opts.cb

    introspect_line: (opts) =>
        opts = defaults opts,
            line     : required
            preparse : true
            cb       : required

        salvus_client.call
            message: message.codemirror_introspect
                line         : opts.line
                preparse     : opts.preparse
                session_uuid : @session_uuid
            cb : opts.cb



    _diffsync_ready: (mesg) =>
        if mesg.session_uuid == @session_uuid
            @sync()

    ui_synced: (synced) =>
        if synced
            if @_ui_synced_timer?
                clearTimeout(@_ui_synced_timer)
                delete @_ui_synced_timer
            @element.find(".salvus-editor-codemirror-not-synced").hide()
            #@element.find(".salvus-editor-codemirror-synced").show()
        else
            if @_ui_synced_timer?
                return
            show_spinner = () =>
                @element.find(".salvus-editor-codemirror-not-synced").show()
                #@element.find(".salvus-editor-codemirror-synced").hide()
            @_ui_synced_timer = setTimeout(show_spinner, 4*@opts.sync_interval)

    init_cursorActivity_event: () =>
        @codemirror.on 'cursorActivity', (instance) =>
            if not @_syncing
                @send_cursor_info_to_hub_soon()
            @editor.local_storage('cursor', @codemirror.getCursor())

    init_chat: () =>
        chat = @element.find(".salvus-editor-codemirror-chat")
        input = chat.find(".salvus-editor-codemirror-chat-input")

        # send chat message
        input.keydown (evt) =>
            if evt.which == 13 # enter
                content = $.trim(input.val())
                if content != ""
                    input.val("")
                    @write_chat_mesg(content)
                return false

        @chat_session.on 'sync', @render_chat_log

        @render_chat_log()  # first time
        @init_chat_toggle()
        @new_chat_indicator(false)

    write_chat_mesg: (content, cb) =>
        s = misc.to_json(new Date())
        chat = misc.to_json
            name : account.account_settings.fullname()
            color: account.account_settings.account_id().slice(0,6)
            date : s.slice(1, s.length-1)
            mesg : {event:'chat', content:content}
        @chat_session.live(@chat_session.live() + "\n" + chat)
        # save to disk after each message
        @chat_session.save(cb)

    init_chat_toggle: () =>
        title = @element.find(".salvus-editor-chat-title")
        title.click () =>
            if @editor._chat_is_hidden? and @editor._chat_is_hidden
                @show_chat_window()
            else
                @hide_chat_window()
        @hide_chat_window()  #start hidden for now, until we have a way to save this state.

    show_chat_window: () =>
        # SHOW the chat window
        @editor._chat_is_hidden = false
        @element.find(".salvus-editor-chat-show").hide()
        @element.find(".salvus-editor-chat-hide").show()
        @element.find(".salvus-editor-codemirror-input-box").removeClass('span12').addClass('span9')
        @element.find(".salvus-editor-codemirror-chat-column").show()
        # see http://stackoverflow.com/questions/4819518/jquery-ui-resizable-does-not-support-position-fixed-any-recommendations
        # if you want to try to make this resizable
        @new_chat_indicator(false)
        @editor.show()  # updates editor width
        @render_chat_log()

    hide_chat_window: () =>
        # HIDE the chat window
        @editor._chat_is_hidden = true
        @element.find(".salvus-editor-chat-hide").hide()
        @element.find(".salvus-editor-chat-show").show()
        @element.find(".salvus-editor-codemirror-input-box").removeClass('span9').addClass('span12')
        @element.find(".salvus-editor-codemirror-chat-column").hide()
        @editor.show()  # update size/display of editor (especially the width)

    new_chat_indicator: (new_chats) =>
        # Show a new chat indicatorif new_chats=true
        # if new_chats=true, indicate that there are new chats
        # if new_chats=false, don't indicate new chats.
        elt = @element.find(".salvus-editor-chat-new-chats")
        elt2 = @element.find(".salvus-editor-chat-no-new-chats")
        if new_chats
            elt.show()
            elt2.hide()
        else
            elt.hide()
            elt2.show()

    render_chat_log: () =>
        messages = @chat_session.live()
        if not @_last_size?
            @_last_size = messages.length

        if @_last_size != messages.length
            @new_chat_indicator(true)
            @_last_size = messages.length
            if not @editor._chat_is_hidden
                f = () =>
                    @new_chat_indicator(false)
                setTimeout(f, 3000)

        if @editor._chat_is_hidden
            # For this right here, we need to use the database to determine if user has seen all chats.
            # But that is a nontrivial project to implement, so save for later.   For now, just start
            # assuming user has seen them.

            # done -- no need to render anything.
            return

        output = @element.find(".salvus-editor-codemirror-chat-output")
        output.empty()

        messages = messages.split('\n')

        if not @_max_chat_length?
            @_max_chat_length = 100

        if messages.length > @_max_chat_length
            output.append($("<a style='cursor:pointer'>(#{messages.length - @_max_chat_length} chats omited)</a><br>"))
            output.find("a:first").click (e) =>
                @_max_chat_length += 100
                @render_chat_log()
                output.scrollTop(0)
            messages = messages.slice(messages.length - @_max_chat_length)

        for m in messages
            if $.trim(m) == ""
                continue
            try
                mesg = JSON.parse(m)
            catch
                continue # skip
            date = new Date(mesg.date)
            entry = templates.find(".salvus-chat-entry").clone()
            output.append(entry)
            header = entry.find(".salvus-chat-header")
            if (not last_chat_name?) or last_chat_name != mesg.name or ((date.getTime() - last_chat_time) > 60000)
                header.find(".salvus-chat-header-name").text(mesg.name).css(color:"#"+mesg.color)
                header.find(".salvus-chat-header-date").attr('title', date.toISOString()).timeago()
            else
                header.hide()
            last_chat_name = mesg.name
            last_chat_time = new Date(mesg.date).getTime()
            entry.find(".salvus-chat-entry-content").text(mesg.mesg.content).mathjax()

        output.scrollTop(output[0].scrollHeight)

    send_broadcast_message: (mesg, self) ->
        m = message.codemirror_bcast
            session_uuid : @session_uuid
            mesg         : mesg
            self         : self    #if true, then also include this client to receive message
        salvus_client.send(m)

    send_cursor_info_to_hub: () =>
        delete @_waiting_to_send_cursor
        if not @session_uuid # not yet connected to a session
            return
        @send_broadcast_message({event:'cursor', pos:@codemirror.getCursor()})

    send_cursor_info_to_hub_soon: () =>
        if @_waiting_to_send_cursor?
            return
        @_waiting_to_send_cursor = setTimeout(@send_cursor_info_to_hub, @opts.cursor_interval)

    _receive_broadcast: (mesg) =>
        if mesg.session_uuid == @session_uuid
            switch mesg.mesg.event
                when 'cursor'
                    @_receive_cursor(mesg)
                when 'update_session_uuid'
                    # This just doesn't work yet -- not really implemented in the hub -- so we force
                    # a full reconnect, which is safe.

                    #@session_uuid = mesg.mesg.new_session_uuid
                    @connect()

    _receive_cursor: (mesg) =>
        # If the cursor has moved, draw it.  Don't bother if it hasn't moved, since it can get really
        # annoying having a pointless indicator of another person.
        if not @_last_cursor_pos?
            @_last_cursor_pos = {}
        else
            pos = @_last_cursor_pos[mesg.color]
            if pos? and pos.line == mesg.mesg.pos.line and pos.ch == mesg.mesg.pos.ch
                return
        # cursor moved.
        @_last_cursor_pos[mesg.color] = mesg.mesg.pos   # record current position
        @_draw_other_cursor(mesg.mesg.pos, '#' + mesg.color, mesg.name)

    # Move the cursor with given color to the given pos.
    _draw_other_cursor: (pos, color, name) =>
        if not @codemirror?
            return
        if not @_cursors?
            @_cursors = {}
        id = color + name
        cursor_data = @_cursors[id]
        if not cursor_data?
            cursor = templates.find(".salvus-editor-codemirror-cursor").clone().show()
            inside = cursor.find(".salvus-editor-codemirror-cursor-inside")
            inside.css
                'background-color': color
            label = cursor.find(".salvus-editor-codemirror-cursor-label")
            label.css('color':color)
            label.text(name)
            cursor_data = {cursor: cursor, pos:pos}
            @_cursors[id] = cursor_data
        else
            cursor_data.pos = pos

        # first fade the label out
        cursor_data.cursor.find(".salvus-editor-codemirror-cursor-label").stop().show().animate(opacity:1).fadeOut(duration:16000)
        # Then fade the cursor out (a non-active cursor is a waste of space).
        cursor_data.cursor.stop().show().animate(opacity:1).fadeOut(duration:60000)
        #console.log("Draw #{name}'s #{color} cursor at position #{pos.line},#{pos.ch}", cursor_data.cursor)
        @codemirror.addWidget(pos, cursor_data.cursor[0], false)

    _save: (cb) =>
        if @editor.opts.delete_trailing_whitespace
            @codemirror.delete_trailing_whitespace()
        super(cb)

    _apply_changeObj: (changeObj) =>
        @codemirror.replaceRange(changeObj.text, changeObj.from, changeObj.to)
        if changeObj.next?
            @_apply_changeObj(changeObj.next)

    refresh_soon: (wait) =>
        if not wait?
            wait = 1000
        if @_refresh_soon?
            # We have already set a timer to do a refresh soon.
            #console.log("not refresh_soon since -- We have already set a timer to do a refresh soon.")
            return
        do_refresh = () =>
            delete @_refresh_soon
            @codemirror.refresh()
        @_refresh_soon = setTimeout(do_refresh, wait)

    interrupt: () =>
        @close_on_action()

    close_on_action: (element) =>
        # Close popups (e.g., introspection) that are set to be closed when an
        # action, such as "execute", occurs.
        if element?
            if not @_close_on_action_elements?
                @_close_on_action_elements = [element]
            else
                @_close_on_action_elements.push(element)
        else if @_close_on_action_elements?
            for e in @_close_on_action_elements
                e.remove()
            @_close_on_action_elements = []

{ MARKERS, FLAGS, ACTION_FLAGS } = diffsync

class SynchronizedWorksheet extends SynchronizedDocument
    constructor: (@editor, opts) ->
        opts0 =
            cursor_interval : opts.cursor_interval
            sync_interval   : opts.sync_interval
        super @editor, opts0, () =>
            @process_sage_updates()

        @init_worksheet_buttons()
        @on 'sync', @process_sage_updates

        @editor.on 'show', (height) =>
            w = @cm_lines().width()
            for mark in @codemirror.getAllMarks()
                elt = @elt_at_mark(mark)
                if elt?
                    if elt.hasClass('sagews-output')
                        # Setting the max height was mainly to deal with Codemirror< 3.14 bugs.
                        #elt.css('max-height', (height*.9) + 'px')
                        elt.css('width', (w-25) + 'px')
                    else if elt.hasClass('sagews-input')
                        elt.css('width', w + 'px')


        @codemirror.on 'beforeChange', (instance, changeObj) =>
            #console.log("beforeChange: #{misc.to_json(changeObj)}")
            if changeObj.origin == 'paste'
                changeObj.cancel()
                # WARNING: The Codemirror manual says "Note: you may not do anything
                # from a "beforeChange" handler that would cause changes to the
                # document or its visualization."  I think this is OK below though
                # since we just canceled the change.
                @remove_cell_flags_from_changeObj(changeObj, ACTION_FLAGS)
                @_apply_changeObj(changeObj)
                @sync () =>
                    @process_sage_updates()

    init_worksheet_buttons: () =>
        buttons = @element.find(".salvus-editor-codemirror-worksheet-buttons")
        buttons.show()
        buttons.find("a").tooltip(delay:{ show: 500, hide: 100 })
        buttons.find("a[href=#execute]").click () =>
            @action(execute:true, advance:true)
            return false
        buttons.find("a[href=#toggle-input]").click () =>
            @action(execute:false, toggle_input:true)
            return false
        buttons.find("a[href=#toggle-output]").click () =>
            @action(execute:false, toggle_output:true)
            return false
        buttons.find("a[href=#delete-output]").click () =>
            @action(execute:false, delete_output:true)
            return false
        buttons.find("a[href=#interrupt]").click () =>
            @interrupt()
            return false
        buttons.find("a[href=#tab]").click () =>
            @editor.press_tab_key(@editor.codemirror_with_last_focus)
            return false
        buttons.find("a[href=#kill]").click () =>
            @kill()
            return false

    _is_dangerous_undo_step: (cm, changes) =>
        for c in changes
            if c.from.line == c.to.line
                line = cm.getLine(c.from.line)
                if line? and line.length > 0 and (line[0] == MARKERS.output or line[0] == MARKERS.cell)
                    return true
            for t in c.text
                if MARKERS.output in t or MARKERS.cell in t
                    return true
        return false

    on_undo: (cm, changeObj) =>
        u = cm.getHistory().undone
        if u.length > 0 and @_is_dangerous_undo_step(cm, u[u.length-1].changes)
            cm.undo()

    on_redo: (cm, changeObj) =>
        u = cm.getHistory().done
        if u.length > 0 and @_is_dangerous_undo_step(cm, u[u.length-1].changes)
            cm.redo()

    interrupt: () =>
        @close_on_action()
        @send_signal(signal:2)

    kill: () =>
        @close_on_action()
        # Set any running cells to not running.
        for marker in @codemirror.getAllMarks()
            if marker.type == MARKERS.cell
                for flag in ACTION_FLAGS
                    @remove_cell_flag(marker, flag)
        @process_sage_updates()
        @send_signal(signal:3)
        setTimeout(( () => @send_signal(signal:9) ), 500 )


    send_signal: (opts) =>
        opts = defaults opts,
            signal : 2
            cb     : undefined
        salvus_client.call
            message: message.codemirror_send_signal
                signal : opts.signal
                session_uuid : @session_uuid
            cb : (err) =>
                @sync()
                setTimeout( (() => @sync()), 50 )
                opts.cb?(err)

    introspect: () =>
        # TODO: obviously this wouldn't work in both sides of split worksheet.
        pos  = @codemirror.getCursor()
        line = @codemirror.getLine(pos.line).slice(0, pos.ch)
        if pos.ch == 0 or line[pos.ch-1] in ")]}'\"\t "
            @codemirror.tab_as_space()
            return
        @introspect_line
            line : line
            cb   : (err, mesg) =>
                if err
                    alert_message(type:"error", message:"Unable to introspect -- #{err}")
                else if mesg.event == "error"
                    alert_message(type:"error", message:"Unable to introspect -- #{mesg.error}")
                else
                    from = {line:pos.line, ch:pos.ch - mesg.target.length}
                    elt = undefined
                    switch mesg.event
                        when 'introspect_completions'
                            @codemirror.showCompletions
                                from             : from
                                to               : pos
                                completions      : mesg.completions
                                target           : mesg.target
                                completions_size : @editor.opts.completions_size

                        when 'introspect_docstring'
                            elt = @codemirror.showIntrospect
                                from      : from
                                content   : mesg.docstring
                                target    : mesg.target
                                type      : "docstring"

                        when 'introspect_source_code'
                            elt = @codemirror.showIntrospect
                                from      : from
                                content   : mesg.source_code
                                target    : mesg.target
                                type      : "source-code"

                        else
                            console.log("BUG -- introspect_line -- unknown event #{mesg.event}")
                    if elt?
                        @close_on_action(elt)

    elt_at_mark: (mark) =>
        elt = mark.replacedWith
        if elt?
            return $($(elt).children()[0])  # codemirror wraps the element -- maybe a bug in codemirror that it does this.

    cm_wrapper: () =>
        if @_cm_wrapper?
            return @_cm_wrapper
        return @_cm_wrapper = $(@codemirror.getWrapperElement())

    cm_lines: () =>
        if @_cm_lines?
            return @_cm_lines
        return @_cm_lines = @cm_wrapper().find(".CodeMirror-lines")


    pad_bottom_with_newlines: (n) =>
        cm = @codemirror
        m = cm.lineCount()
        if m <= 13  # don't bother until worksheet gets big
            return
        j = m-1
        while j >= 0 and j >= m-n and cm.getLine(j).length == 0
            j -= 1
        k = n - (m - (j + 1))
        if k > 0
            cursor = cm.getCursor()
            cm.replaceRange(Array(k+1).join('\n'), {ch:0, line:m} )
            cm.setCursor(cursor)

    process_sage_updates: (start) =>
        #console.log("processing Sage updates")
        # For each line in the editor (or starting at line start), check if the line
        # starts with a cell or output marker and is not already marked.
        # If not marked, mark it appropriately, and possibly process any
        # changes to that line.
        cm = @codemirror
        if not start?
            start = 0

        @pad_bottom_with_newlines(10)

        for line in [start...cm.lineCount()]
            x = cm.getLine(line)

            if x[0] == MARKERS.cell
                marks = cm.findMarksAt({line:line, ch:1})
                if marks.length == 0
                    @mark_cell_start(line)
                else
                    first = true
                    for mark in marks
                        if not first # there should only be one mark
                            mark.clear()
                            continue
                        first = false
                        # The mark should only span one line:
                        #   insertions when applying a patch can unfortunately mess this up,
                        #   so we have to re-do any that accidentally span multiple lines.
                        m = mark.find()
                        if m.from.line != m.to.line
                            mark.clear()
                            @mark_cell_start(line)
                flagstring = x.slice(37, x.length-1)
                mark = cm.findMarksAt({line:line, ch:1})[0]
                # It's possible mark isn't defined above, in case of some weird file corruption (say
                # intentionally by the user).  That's why we have "mark?" in the condition below.
                if mark? and flagstring != mark.flagstring
                    if not mark.flagstring?
                        mark.flagstring = ''
                    # only do something if the flagstring changed.
                    elt = @elt_at_mark(mark)
                    if FLAGS.execute in flagstring
                        # execute requested
                        elt.spin(true)
                    else if FLAGS.running in flagstring
                        # code is running on remote local hub.
                        elt.spin(color:'green')
                    else
                        # code is not running
                        elt.spin(false)
                    if FLAGS.hide_input in flagstring and FLAGS.hide_input not in mark.flagstring
                        @hide_input(line)
                    else if FLAGS.hide_input in mark.flagstring and FLAGS.hide_input not in flagstring
                        @show_input(line)

                    if FLAGS.hide_output in flagstring and FLAGS.hide_output not in mark.flagstring
                        @hide_output(line)
                    else if FLAGS.hide_output in mark.flagstring and FLAGS.hide_output not in flagstring
                        @show_output(line)

                    mark.flagstring = flagstring

            else if x[0] == MARKERS.output
                marks = cm.findMarksAt({line:line, ch:1})
                if marks.length == 0
                    @mark_output_line(line)
                mark = cm.findMarksAt({line:line, ch:1})[0]
                uuid = cm.getRange({line:line,ch:1}, {line:line,ch:37})
                if mark.uuid != uuid # uuid changed -- completely new output
                    #console.log("uuid change: new x = ", x)
                    mark.processed = 38
                    mark.uuid = uuid
                    @elt_at_mark(mark).html('')
                if mark.processed < x.length
                    #console.log("length change; x = ", x)
                    # new output to process
                    t = x.slice(mark.processed, x.length-1)
                    mark.processed = x.length
                    for s in t.split(MARKERS.output)
                        if s.length > 0
                            output = @elt_at_mark(mark)
                            # appearance of output shows output (bad design?)
                            output.removeClass('sagews-output-hide')
                            try
                               @process_output_mesg(mesg:JSON.parse(s), element:output)
                            catch e
                                log("BUG: error rendering output: '#{s}' -- #{e}")

            else if x.indexOf(MARKERS.output) != -1
                #console.log("correcting merge/paste issue with output marker line (line=#{line})")
                ch = x.indexOf(MARKERS.output)
                cm.replaceRange('\n', {line:line, ch:ch})
                @process_sage_updates(line)
                return

            else if x.indexOf(MARKERS.cell) != -1
                #console.log("correcting merge/paste issue with cell marker (line=#{line})")
                ch = x.indexOf(MARKERS.cell)
                cm.replaceRange('\n', {line:line, ch:ch})
                @process_sage_updates(line)
                return

    ##################################################################################
    # Toggle visibility of input/output portions of cells -
    #    This is purely a client-side display function; it doesn't change
    #    the document or cause any sync to happen!
    ##################################################################################

    # hide_input: hide input part of cell that has start marker at the given line.
    hide_input: (line) =>
        end = line+1
        cm = @codemirror
        while end < cm.lineCount()
            c = cm.getLine(end)[0]
            if c == MARKERS.cell or c == MARKERS.output
                break
            end += 1

        line += 1

        #hide = $("<div>")
        opts =
            shared         : false
            inclusiveLeft  : true
            inclusiveRight : true
            atomic         : true
            #replacedWith   : hide[0]
            collapsed      : true   # yeah, collapsed now works right in CodeMirror 3.14
        marker = cm.markText({line:line, ch:0}, {line:end-1, ch:cm.getLine(end-1).length}, opts)
        marker.type = 'hide_input'
        @editor.show()

    show_input: (line) =>
        cm = @codemirror
        for marker in cm.findMarksAt({line:line+1, ch:0})
            if marker.type == 'hide_input'
                marker.clear()
                @editor.show()

    hide_output: (line) =>
        mark = @find_output_mark(line)
        if mark?
            @elt_at_mark(mark).addClass('sagews-output-hide')
            @editor.show()

    show_output: (line) =>
        mark = @find_output_mark(line)
        if mark?
            @elt_at_mark(mark).removeClass('sagews-output-hide')
            @editor.show()

    execute_code: (opts) ->
        opts = defaults opts,
            code     : required
            cb       : undefined
            data     : undefined
            preparse : true
            uuid     : undefined

        if opts.uuid?
            uuid = opts.uuid
        else
            uuid = misc.uuid()

        if opts.cb?
            salvus_client.execute_callbacks[uuid] = opts.cb

        salvus_client.send(
            message.codemirror_execute_code
                session_uuid : @session_uuid
                id           : uuid
                code         : opts.code
                data         : opts.data
                preparse     : opts.preparse
        )

        return uuid

    interact: (output, desc) =>
        # Create and insert DOM objects corresponding to the interact
        elt = $("<div class='sagews-output-interact'>")
        interact_elt = $("<span>")
        elt.append(interact_elt)
        output.append(elt)

        # Call jQuery plugin to make it all happen.
        interact_elt.sage_interact(desc:desc, execute_code:@execute_code, process_output_mesg:@process_output_mesg)

    process_output_mesg: (opts) =>
        opts = defaults opts,
            mesg    : required
            element : required
            mark     : undefined
        mesg = opts.mesg
        output = opts.element
        # mesg = object
        # output = jQuery wrapped element

        #console.log("new output: ", mesg)

        if mesg.stdout?
            output.append($("<span class='sagews-output-stdout'>").text(mesg.stdout))

        if mesg.stderr?
            output.append($("<span class='sagews-output-stderr'>").text(mesg.stderr))

        if mesg.html?
            output.append($("<div class='sagews-output-html'>").html(mesg.html).mathjax())

        if mesg.interact?
            @interact(output, mesg.interact)

        if mesg.tex?
            val = mesg.tex
            elt = $("<span class='sagews-output-tex'>")
            arg = {tex:val.tex}
            if val.display
                arg.display = true
            else
                arg.inline = true
            output.append(elt.mathjax(arg))

        if mesg.file?
            val = mesg.file
            if not val.show? or val.show
                target = "/blobs/#{val.filename}?uuid=#{val.uuid}"
                switch misc.filename_extension(val.filename)
                    # TODO: harden DOM creation below
                    when 'svg', 'png', 'gif', 'jpg'
                        output.append($("<img src='#{target}' class='sagews-output-image'>"))
                    else
                        output.append($("<a href='#{target}' class='sagews-output-link' target='_new'>#{val.filename} (this temporary link expires in a minute)</a> "))

        if mesg.javascript? and @editor.opts.allow_javascript_eval
            (() =>
             cell      = new Cell(output :opts.element)
             worksheet = new Worksheet(@)

             code = mesg.javascript.code
             if mesg.javascript.coffeescript
                 code = CoffeeScript.compile(code)
             obj  = JSON.parse(mesg.obj)

             #console.log("executing script: '#{code}', obj='#{mesg.obj}'")

             # The eval below is an intentional cross-site scripting vulnerability in the fundamental design of Salvus.
             # Note that there is an allow_javascript document option, which (at some point) users
             # will be able to set.
             eval(code)
            )()

        if mesg.done? and mesg.done
            output.removeClass('sagews-output-running')
            output.addClass('sagews-output-done')

        @refresh_soon()

    mark_cell_start: (line) =>
        # Assuming the proper text is in the document for a new cell at this line,
        # mark it as such. This hides control codes and places a cell separation
        # element, which may be clicked to create a new cell.
        cm  = @codemirror
        if line >= cm.lineCount()-1
            # If at bottom, insert blank lines.
            cm.replaceRange("\n\n\n", {line:line+1, ch:0})
        x   = cm.getLine(line)
        end = x.indexOf(MARKERS.cell, 1)
        input = cell_start_template.clone().css
            width : @cm_lines().width() + 'px'

        input.click () =>
            f = () =>
                @insert_new_cell(mark.find().from.line)
            if IS_MOBILE
                # It is way too easy to accidentally click on the insert new cell line on mobile.
                bootbox.confirm "Create new cell?", (result) =>
                    if result
                        f()
                    else # what the user really wants...
                        cm.focus()
                        cm.setCursor({line:mark.find().from.line+1, ch:0})
            else
                f()
            return false

        opts =
            shared         : false
            inclusiveLeft  : false
            inclusiveRight : true
            atomic         : true
            replacedWith   : input[0]
        mark = cm.markText({line:line, ch:0}, {line:line, ch:end+1}, opts)
        mark.type = MARKERS.cell
        return mark

    mark_output_line: (line) =>
        # Assuming the proper text is in the document for output to be displayed at this line,
        # mark it as such.  This hides control codes and creates a div into which output will
        # be placed as it appears.

        cm = @codemirror

        # WARNING: Having a max-height that is SMALLER than the containing codemirror editor was *critical*
        # before Codemirror 3.14, due to a bug.
        output = output_template.clone().css
            width        : (@cm_lines().width()-25) + 'px'
            #'max-height' : (.9*@cm_wrapper().height()) + 'px'


        if cm.lineCount() < line + 2
            cm.replaceRange('\n', {line:line+1,ch:0})
        start = {line:line, ch:0}
        end = {line:line, ch:cm.getLine(line).length}
        opts =
            shared         : false
            inclusiveLeft  : false
            inclusiveRight : true
            atomic         : true
            replacedWith   : output[0]
        mark = cm.markText(start, end, opts)
        # mark.processed stores how much of the output line we
        # have processed  [marker]36-char-uuid[marker]
        mark.processed = 38
        mark.uuid = cm.getRange({line:line, ch:1}, {line:line, ch:37})
        mark.type = MARKERS.output

        # Double click output to toggle input
        output.dblclick () =>
            @action(pos:{line:mark.find().from.line-1, ch:0}, toggle_input:true)

        return mark

    find_output_line: (line) =>
        # Given a line number in the editor, return the nearest (greater or equal) line number that
        # is an output line, or undefined if there is no output line before the next cell.
        cm = @codemirror
        if cm.getLine(line)[0] == MARKERS.output
            return line
        line += 1
        while line < cm.lineCount() - 1
            x = cm.getLine(line)
            if x.length > 0
                if x[0] == MARKERS.output
                    return line
                if x[0] == MARKERS.cell
                    return undefined
            line += 1
        return undefined

    find_output_mark: (line) =>
        # Same as find_output_line, but returns the actual mark (or undefined).
        n = @find_output_line(line)
        if n?
            for mark in @codemirror.findMarksAt({line:n, ch:0})
                if mark.type == MARKERS.output
                    return mark
        return undefined

    # Returns start and end lines of the current input block (if line is undefined),
    # or of the block that contains the given line number.
    current_input_block: (line) =>
        cm = @codemirror
        if not line?
            line = cm.getCursor().line

        start = line
        end   = line
        while start > 0
            x = cm.getLine(start)
            if x.length > 0 and x[0] == MARKERS.cell
                break
            start -= 1
        while end < cm.lineCount()-1
            x = cm.getLine(end)
            if x.length > 0 and x[0] == MARKERS.cell
                end -= 1
                break
            end += 1
        return {start:start, end:end}

    action: (opts={}) =>
        opts = defaults opts,
            pos     : undefined # if given, use this pos; otherwise, use where cursor is or all cells in selection
            advance : false
            split   : false # split cell at cursor (selection is ignored)
            execute : false # if false, do whatever else we would do, but don't actually execute code.
            toggle_input  : false  # if true; toggle whether input is displayed; ranges all toggle same as first
            toggle_output : false  # if true; toggle whether output is displayed; ranges all toggle same as first
            delete_output : false  # if true; delete all the the output in the range
            cm      : @codemirror
        if opts.pos?
            pos = opts.pos
        else
            if opts.cm.somethingSelected() and not opts.split
                opts.advance = false
                start = opts.cm.getCursor('start').line
                end   = opts.cm.getCursor('end').line
                # Expand both ends of the selection to contain cell containing cursor
                start = @current_input_block(start).start
                end   = @current_input_block(end).end

                # These @_toggle attributes are used to ensure that we toggle all the input and output
                # view states so they end up the same.
                @_toggle_input_range  = 'wait'
                @_toggle_output_range = 'wait'

                # For each line in the range, check if it is the beginning of a cell; if so do the action on it.
                for line in [start..end]  # include end
                    x = opts.cm.getLine(line)
                    if x? and x[0] == MARKERS.cell
                        opts.pos = {line:line, ch:0}
                        @action(opts)

                delete @_toggle_input_range
                delete @_toggle_output_range
                return
            else
                pos = opts.cm.getCursor()

        @close_on_action()  # close introspect popups

        if opts.split
            @split_cell_at(pos)
            if opts.execute
                opts.split = false
                opts.advance = false
                opts.cm.setCursor(line:pos.line, ch:0)
                @action(opts)
                @move_cursor_to_next_cell()
                @action(opts)
            else
                @sync()
            return

        if opts.delete_output
            n = @find_output_line(pos.line)
            if n?
                opts.cm.removeLine(n)
                @sync()
            return

        block = @current_input_block(pos.line)

        # create or get cell start mark
        marker = @cell_start_marker(block.start)

        if opts.toggle_input
            if FLAGS.hide_input in @get_cell_flagstring(marker)
                # input is currently hidden
                if @_toggle_input_range != 'hide'
                    @remove_cell_flag(marker, FLAGS.hide_input)   # show input
                if @_toggle_input_range == 'wait'
                    @_toggle_input_range = 'show'
            else
                # input is currently shown
                if @_toggle_input_range != 'show'
                    @set_cell_flag(marker, FLAGS.hide_input)  # hide input
                if @_toggle_input_range == 'wait'
                    @_toggle_input_range = 'hide'

            @sync()

        if opts.toggle_output
            if FLAGS.hide_output in @get_cell_flagstring(marker)
                # output is currently hidden
                if @_toggle_output_range != 'hide'
                    @remove_cell_flag(marker, FLAGS.hide_output)  # show output
                if @_toggle_output_range == 'wait'
                    @_toggle_output_range = 'show'
            else
                if @_toggle_output_range != 'show'
                    @set_cell_flag(marker, FLAGS.hide_output)
                if @_toggle_output_range == 'wait'
                    @_toggle_output_range = 'hide'

            @sync()

        if opts.advance
            @move_cursor_to_next_cell()

        if opts.execute
            @set_cell_flag(marker, FLAGS.execute)
            @sync()
            setTimeout( (() => @sync()), 50 )
            setTimeout( (() => @sync()), 200 )


    _diffsync_ready: (mesg) =>
        if mesg.session_uuid == @session_uuid
            @sync()

    split_cell_at: (pos) =>
        # Split the cell at the given pos.
        @cell_start_marker(pos.line)
        @sync()

    move_cursor_to_next_cell: () =>
        cm = @codemirror
        line = cm.getCursor().line + 1
        while line < cm.lineCount()
            x = cm.getLine(line)
            if x.length > 0 and x[0] == MARKERS.cell
                cm.setCursor(line:line+1, ch:0)
                return
            line += 1
        # there is no next cell, so we create one at the last non-whitespace line
        while line > 0 and $.trim(cm.getLine(line)).length == 0
            line -= 1
        @cell_start_marker(line+1)
        cm.setCursor(line:line+2, ch:0)

    ##########################################
    # Codemirror-based cell manipulation code
    #   This is tightly tied to codemirror, so only makes sense on the client.
    ##########################################
    get_cell_flagstring: (marker) =>
        pos = marker.find()
        return @codemirror.getRange({line:pos.from.line,ch:37},{line:pos.from.line, ch:pos.to.ch-1})

    set_cell_flagstring: (marker, value) =>
        pos = marker.find()
        @codemirror.replaceRange(value, {line:pos.from.line,ch:37}, {line:pos.to.line, ch:pos.to.ch-1})

    get_cell_uuid: (marker) =>
        pos = marker.find()
        return @codemirror.getLine(pos.line).slice(1,38)

    set_cell_flag: (marker, flag) =>
        s = @get_cell_flagstring(marker)
        if flag not in s
            @set_cell_flagstring(marker, flag + s)

    remove_cell_flag: (marker, flag) =>
        s = @get_cell_flagstring(marker)
        if flag in s
            s = s.replace(new RegExp(flag, "g"), "")
            @set_cell_flagstring(marker, s)

    insert_new_cell: (line) =>
        pos = {line:line, ch:0}
        @codemirror.replaceRange('\n', pos)
        @codemirror.focus()
        @codemirror.setCursor(pos)
        @cell_start_marker(line)
        @process_sage_updates()
        @sync()

    cell_start_marker: (line) =>
        cm = @codemirror
        x = cm.findMarksAt(line:line, ch:1)
        if x.length > 0 and x[0].type == MARKERS.cell
            # already properly marked
            return x[0]
        if cm.lineCount() < line + 2
            cm.replaceRange('\n',{line:line+1,ch:0})
        uuid = misc.uuid()
        cm.replaceRange(MARKERS.cell + uuid + MARKERS.cell + '\n', {line:line, ch:0})
        return @mark_cell_start(line)

    remove_cell_flags_from_changeObj: (changeObj, flags) =>
        # Remove cell flags from *contiguous* text in the changeObj.
        # This is useful for cut/copy/paste, but useless for
        # diffsync (where we would not use it anyways).
        # This function modifies changeObj in place.
        @remove_cell_flags_from_text(changeObj.text, flags)
        if changeObj.next?
            @remove_cell_flags_from_changeObj(changeObj.next, flags)

    remove_cell_flags_from_text: (text, flags) =>
        # !! The input "text" is an array of strings, one for each line;
        # this function modifies this array in place.
        # Replace all lines of the form
        #    [MARKERS.cell][36-character uuid][flags][MARKERS.cell]
        # by
        #    [MARKERS.cell][uuid][flags2][MARKERS.cell]
        # where flags2 has the flags in the second argument (an array) removed,
        # or all flags removed if the second argument is undefined
        for i in [0...text.length]
            s = text[i]
            if s.length >= 38 and s[0] == MARKERS.cell
                if flags?
                    text[i] = s.slice(0,37) + (x for x in s.slice(37,s.length-1) when x not in flags) + MARKERS.cell
                else
                    text[i] = s.slice(0,37) + MARKERS.cell


class Cell
    constructor : (opts) ->
        opts = defaults opts,
            output : required # jquery wrapped output area
            #cell_mark   : required # where cell starts

class Worksheet

    constructor : (@worksheet) ->

    execute_code: (opts) =>
        if typeof opts == "string"
            opts = {code:opts}
        @worksheet.execute_code(opts)

    interrupt: () =>
        @worksheet.interrupt()

    kill: () =>
        @worksheet.kill()

    set_interact_var : (opts) =>
        elt = @worksheet.element.find("#" + opts.id)
        if elt.length == 0
            log("BUG: Attempt to set var of interact with id #{opts.id} failed since no such interact known.")
        else
            i = elt.data('interact')
            if not i?
                log("BUG: interact with id #{opts.id} doesn't have corresponding data object set.", elt)
            else
                i.set_interact_var(opts)

    del_interact_var : (opts) =>
        elt = @worksheet.element.find("#" + opts.id)
        if elt.length == 0
            log("BUG: Attempt to del var of interact with id #{opts.id} failed since no such interact known.")
        else
            i = elt.data('interact')
            if not i?
                log("BUG: interact with id #{opts.id} doesn't have corresponding data object del.", elt)
            else
                i.del_interact_var(opts.name)

################################
exports.SynchronizedDocument = SynchronizedDocument
exports.SynchronizedWorksheet = SynchronizedWorksheet





