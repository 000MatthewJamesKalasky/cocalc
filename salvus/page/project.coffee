###############################################################################
#
# Project page -- browse the files in a project, etc.
#
###############################################################################

{IS_MOBILE} = require("feature")
{top_navbar}    = require('top_navbar')
{salvus_client} = require('salvus_client')
message         = require('message')
{alert_message} = require('alerts')
async           = require('async')
misc            = require('misc')
diffsync        = require('diffsync')
account         = require('account')
{filename_extension, defaults, required, to_json, from_json, trunc, keys, uuid} = misc
{file_associations, Editor, local_storage} = require('editor')
{scroll_top, human_readable_size, download_file} = require('misc_page')

MAX_TITLE_LENGTH = 15

templates = $("#salvus-project-templates")
template_project_file          = templates.find(".project-file-link")
template_project_directory     = templates.find(".project-directory-link")
template_project_file_snapshot      = templates.find(".project-file-link-snapshot")
template_project_directory_snapshot = templates.find(".project-directory-link-snapshot")
template_home_icon             = templates.find(".project-home-icon")
template_segment_sep           = templates.find(".project-segment-sep")
template_project_commits       = templates.find(".project-commits")
template_project_commit_single = templates.find(".project-commit-single")
template_project_branch_single = templates.find(".project-branch-single")
template_project_collab        = templates.find(".project-collab")
template_project_linked        = templates.find(".project-linked")

################################O##################
# Initialize the modal project management dialogs
##################################################
delete_path_dialog = $("#project-delete-path-dialog")
move_path_dialog   = $("#project-move-path-dialog")

class Dialog
    constructor: (opts) ->
        opts = defaults opts,
            dialog      : required
            submit      : required
            before_show : undefined
            after_show  : undefined

        @opts = opts

        submit = () =>
            try
                opts.dialog.modal('hide')
                opts.submit(opts.dialog, @project)
            catch e
                console.log("Exception submitting modal: ", e)
            return false

        opts.dialog.submit submit
        opts.dialog.find("form").submit submit
        opts.dialog.find(".btn-submit").click submit
        opts.dialog.find(".btn-close").click(() -> opts.dialog.modal('hide'); return false)

    show: (project) =>
        @project = project
        @opts.before_show(@opts.dialog, project)
        @opts.dialog.modal()
        @opts.after_show(@opts.dialog, project)
        return false

delete_path_dialog = new Dialog
    dialog      : $("#project-delete-path-dialog")
    submit      : (dialog, project) ->
        path = project.current_path.join('/')
        commit_mesg = dialog.find("input[type=text]").val()
        if commit_mesg == ""
            commit_mesg = "deleted #{path}"
        project.path_action
            action      : 'delete'
            branch      : project.meta.display_branch
            path        : path
            commit_mesg : commit_mesg

    before_show : (dialog, project) ->
        dialog.find(".project-delete-path-dialog-filename").text(project.current_pathname())
        dialog.find("input[type=text]").val("")
    after_show  : (dialog) ->
        dialog.find("input[type=text]").focus()

move_path_dialog = new Dialog
    dialog      : $("#project-move-path-dialog")
    submit      : (dialog, project) ->
        src      = project.current_pathname()
        dest     = dialog.find("input[name=new-filename]").val()
        if src == dest
            # nothing to do
            return
        why      = dialog.find("input[name=why]").val()
        if why == ""
            why = "move #{src} to #{dest}"
        project.path_action
            action      : 'move'
            branch      : project.meta.display_branch
            path        : src
            commit_mesg : why
            extra_options : {dest:dest}
    before_show : (dialog, project) ->
        dialog.find(".project-move-path-dialog-filename").text(project.current_pathname())
        dialog.find("input[name=new-filename]").val(project.current_pathname())
        dialog.find("input[name=why]").val("")
    after_show  : (dialog) ->
        dialog.find("input[name=new-filename]").focus()



##################################################
# Define the project page class
##################################################

class ProjectPage
    constructor: (@project) ->
        @container = templates.find(".salvus-project").clone()
        $("body").append(@container)

        # Create a new tab in the top navbar (using top_navbar as a jquery plugin)
        @container.top_navbar
            id    : @project.project_id
            label : @project.project_id
            icon  : 'fa-edit'
            onclose : () =>
                @editor?.close_all_open_files()
                @save_browser_local_data()
                delete project_pages[@project.project_id]
                @project_log?.disconnect_from_session()
                clearInterval(@_update_last_snapshot_time)
            onshow: () =>
                if @project?
                    document.title = "Project - #{@project.title}"
                    @push_state()
                @editor?.refresh()

            onfullscreen: (entering) =>
                if @project?
                    if entering
                        @hide_tabs()
                    else
                        @show_tabs()
                    $(window).resize()

        $(window).resize () => @window_resize()
        @_update_file_listing_size()

        @init_sort_files_icon()

        # Initialize the search form.
        @init_search_form()

        # Initialize new worksheet/xterm/etc. console buttons

        # current_path is a possibly empty list of directories, where
        # each one is contained in the one before it.
        @current_path = []

        @init_tabs()

        @update_topbar()

        @create_editor()

        @init_file_search()

        @init_new_file_tab()

        @init_refresh_files()
        @init_hidden_files_icon()
        @init_trash_link()
        @init_snapshot_link()

        @init_project_activity()  # must be after @create_editor()

        @init_project_download()

        @init_project_restart()
        @init_worksheet_server_restart()

        @init_delete_project()
        @init_undelete_project()

        @init_make_public()
        @init_make_private()

        @update_collaborators = @init_add_collaborators()
        @init_add_noncloud_collaborator()

        #@update_linked_projects = @init_linked_projects()

        @init_move_project()

        # Set the project id
        @container.find(".project-id").text(@project.project_id)
        if window.salvus_base_url != "" # TODO -- should use a better way to decide dev mode.
            @container.find(".salvus-project-id-warning").show()

        @set_location()

        if @project.size? and @project.size
            @container.find(".project-size").text(human_readable_size(@project.size))
        else
            @container.find(".project-size-label").hide()

        # Set the project location
        #if @project.location?
        #    l = @project.location
        #    l = "#{l.username}@#{l.host}:#{l.path}" + (if l.port != 22 then " -p #{l.port}" else "")
        #    @container.find(".project-location").text(l)#.attr('contenteditable', true).blur () ->
            #    alert_message(message:"Changing project location not yet implemented.", type:'info')
                # TODO -- actually implement project location change -- show a notification and send
                # a message if makes sense; otherwise, don't.  Also, we should store all past
                # project location in the database, and make it possible for the user to see them (?).
                # console.log('changed to ', $(@).text())

        # Make it so editing the title and description of the project
        # sends a message to the hub.
        that = @
        @container.find(".project-project_title").blur () ->
            new_title = $(@).text()
            if new_title != that.project.title
                salvus_client.update_project_data
                    project_id : that.project.project_id
                    data       : {title:new_title}
                    cb         : (err, mesg) ->
                        if err
                            $(@).text(that.project.title)  # change it back
                            alert_message(type:'error', message:"Error contacting server to save modified project title.")
                        else if mesg.event == "error"
                            $(@).text(that.project.title)  # change it back
                            alert_message(type:'error', message:mesg.error)
                        else
                            that.project.title = new_title
                            # Also, change the top_navbar header.
                            that.update_topbar()

        @container.find(".project-project_description").blur () ->
            new_desc = $(@).text()
            if new_desc != that.project.description
                salvus_client.update_project_data
                    project_id : that.project.project_id
                    data       : {description:new_desc}
                    cb         : (err, mesg) ->
                        if err
                            $(@).text(that.project.description)   # change it back
                            alert_message(type:'error', message:err)
                        else if mesg.event == "error"
                            $(@).text(that.project.description)   # change it back
                            alert_message(type:'error', message:mesg.error)
                        else
                            that.project.description = new_desc

        # Activate the command line
        cmdline = @container.find(".project-command-line-input").tooltip(delay:{ show: 500, hide: 100 })
        cmdline.keydown (evt) =>
            if evt.which == 13 # enter
                try
                    that.command_line_exec()
                catch e
                    console.log(e)
                return false
            if evt.which == 27 # escape
                @container?.find(".project-command-line-output").hide()
                return false

        # TODO: this will be for command line tab completion
        #cmdline.keydown (evt) =>
        #    if evt.which == 9
        #        @command_line_tab_complete()
        #        return false


        # Make it so typing something into the "create a new branch..." box
        # makes a new branch.
        #@container.find(".project-branches").find('form').submit () ->
        #    that.branch_op(branch:$(@).find("input").val(), op:'create')
        #    return false

        file_tools = @container.find(".project-file-tools")

        file_tools.find("a[href=#delete]").click () ->
            if not $(@).hasClass("disabled")
                delete_path_dialog.show(that)
            return false

        file_tools.find("a[href=#move]").click () ->
            if not $(@).hasClass("disabled")
                move_path_dialog.show(that)
            return false

        @init_file_sessions()

    push_state: (url) =>
        if not url?
            url = @_last_history_state
        if not url?
            url = ''
        @_last_history_state = url
        #if @project.name? and @project.owner?
            #window.history.pushState("", "", window.salvus_base_url + '/projects/' + @project.ownername + '/' + @project.name + '/' + url)
        # For now, we are just going to default to project-id based URL's, since they are stable and will always be supported.
        # I can extend to the above later in another release, without any harm.
        window.history.pushState("", "", window.salvus_base_url + '/projects/' + @project.project_id + '/' + url)


    #  files/....
    #  recent
    #  new
    #  log
    #  settings
    #  search
    load_target: (target, foreground=true) =>
        #console.log("project -- load_target=#{target}")
        segments = target.split('/')
        switch segments[0]
            when 'recent'
                @display_tab("project-editor")
            when 'files'
                if target[target.length-1] == '/'
                    # open a directory
                    @display_tab("project-file-listing")
                    @current_path = target.slice(0,target.length-1).split('/').slice(1)
                    @update_file_list_tab()
                else
                    # open a file
                    @display_tab("project-editor")
                    @open_file(path:segments.slice(1).join('/'), foreground:foreground)
                    @current_path = segments.slice(1, segments.length-1)
            when 'new'
                @current_path = segments.slice(1)
                @display_tab("project-new-file")
            when 'log'
                @display_tab("project-activity")
            when 'settings'
                @display_tab("project-settings")
            when 'search'
                @current_path = segments.slice(1)
                @display_tab("project-search")

    set_location: () =>
        if @project.location? and @project.location.host?
            x = @project.location.host
        else
            x = "..."
        @container.find(".project-location").text(x)

    window_resize: () =>
        if @current_tab.name == "project-file-listing"
            @_update_file_listing_size()

    _update_file_listing_size: () =>
        elt = @container.find(".project-file-listing-container")
        elt.height($(window).height() - elt.offset().top)


    close: () =>
        top_navbar.remove_page(@project.project_id)

    # Reload the @project attribute from the database, and re-initialize
    # ui elements, mainly in settings.
    reload_settings: (cb) =>
        salvus_client.project_info
            project_id : @project.project_id
            cb         : (err, info) =>
                if err
                    cb?(err)
                    return
                @project = info
                @update_topbar()
                cb?()


    ########################################
    # Launch open sessions
    ########################################

    # TODO -- not used right now -- just use init_file_sessions only -- delete this.
    init_open_sessions: (cb) =>
        salvus_client.project_session_info
            project_id: @project.project_id
            cb: (err, mesg) =>
                if err
                    alert_message(type:"error", message:"Error getting open sessions -- #{err}")
                    cb?(err)
                    return
                console.log(mesg)
                if not (mesg? and mesg.info?)
                    cb?()
                    return

                async.series([
                    (cb) =>
                        @init_console_sessions(mesg.info.console_sessions, cb)
                    (cb) =>
                        @init_sage_sessions(mesg.info.sage_sessions, cb)
                    (cb) =>
                        @init_file_sessions(mesg.info.file_sessions, cb)
                ], (err) => cb?(err))

    # TODO -- not used right now -- just use init_file_sessions only -- delete this.
    init_console_sessions: (sessions, cb) =>
        #console.log("initialize console sessions: ", sessions)
        #@display_tab("project-editor")
        for session_uuid, obj of sessions
            if obj.status == 'running'
                filename = "scratch/#{session_uuid.slice(0,8)}.sage-terminal"
                auto_open = local_storage(@project.project_id, filename, 'auto_open')
                if not auto_open? or auto_open
                    tab = @editor.create_tab(filename:filename, session_uuid:session_uuid)
        cb?()

    # TODO -- not used right now -- just use init_file_sessions only -- delete this.
    init_sage_sessions: (sessions, cb) =>
        #console.log("initialize sage sessions: ", sessions)
        #TODO -- not enough info to do this yet.
        #for session_uuid, obj of sessions
        #    tab = @editor.create_tab(filename : obj.path, session_uuid:session_uuid)
        cb?()

    init_file_sessions: (sessions, cb) =>
        for filename, data of local_storage(@project.project_id)
            if data.auto_open
                tab = @editor.create_tab(filename : filename)
        cb?()

    ########################################
    # Search
    ########################################

    init_file_search: () =>
        @_file_search_box = @container.find(".salvus-project-search-for-file-input")
        @_file_search_box.keyup (event) =>
            if (event.metaKey or event.ctrlKey) and event.keyCode == 79
                @display_tab("project-editor")
                return false
            @update_file_search(event)
        @container.find(".salvus-project-search-for-file-input-clear").click () =>
            @_file_search_box.val('').focus()
            @update_file_search()

    clear_file_search: () =>
        @_file_search_box.val('')

    focus_file_search: () =>
        if not IS_MOBILE
            @_file_search_box.focus()

    update_file_search: (event) =>
        search_box = @_file_search_box
        include = 'project-listing-search-include'
        exclude = 'project-listing-search-exclude'
        v = $.trim(search_box.val()).toLowerCase()

        listing = @container.find(".project-file-listing-file-list")

        if v == ""
            # remove all styling
            for entry in listing.children()
                $(entry).removeClass(include)
                $(entry).removeClass(exclude)
            match = (s) -> true
        else
            terms = v.split(' ')
            match = (s, is_dir) ->
                s = s.toLowerCase()
                for t in terms
                    if t == '/'
                        if not is_dir
                            return false
                    else if s.indexOf(t) == -1
                        return false
                return true

        first = true
        for e in listing.children()
            entry = $(e)
            fullpath = entry.data('name')
            filename = misc.path_split(fullpath).tail
            if match(filename, entry.hasClass('project-directory-link'))
                if first and event?.keyCode == 13 # enter -- select first match (if any)
                    entry.click()
                    first = false
                if v != ""
                    entry.addClass(include); entry.removeClass(exclude)
            else
                if v != ""
                    entry.addClass(exclude); entry.removeClass(include)
        if first and event?.keyCode == 13
            # No matches at all, and user pressed enter -- maybe they want to create a file?
            @display_tab("project-new-file")
            @new_file_tab_input.val(search_box.val())

    init_search_form: () =>
        that = @
        input_boxes = @container.find(".project-search-form-input")
        input_boxes.keypress (evt) ->
            t = $(@)
            if evt.which== 13
                input_boxes.blur()
                # Do the search.
                try
                    that.search(t.val())
                catch e
                    console.log(e)
                return false

        @container.find(".project-search-output-recursive").change () =>
            @search($(input_boxes[0]).val())
        @container.find(".project-search-output-case-sensitive").change () =>
            @search($(input_boxes[0]).val())

        @container.find(".project-search-form-input-clear").click () =>
            input_boxes.val('')
            return false

    search: (query) =>
        if $.trim(query) == ""
            return
        @display_tab("project-search")
        @container.find(".project-search-output-path-heading").show()
        @container.find(".project-search-output-terms").text(query)
        search_output = @container.find(".project-search-output").show().empty()
        recursive   = @container.find(".project-search-output-recursive").is(':checked')
        insensitive = not @container.find(".project-search-output-case-sensitive").is(':checked')
        max_results = 1000
        max_output  = 110*max_results  # just in case
        if insensitive
            ins = " -i "
        else
            ins = ""
        query = '"' + query.replace(/"/g, '\\"') + '"'
        if recursive
            cmd = "find * -type f | grep #{ins} #{query}; rgrep -H #{ins} #{query} * "
        else
            cmd = "ls -1 | grep #{ins} #{query}; grep -H #{ins} #{query} * "

        # Exclude worksheet input cell markers
        cmd += " | grep -v #{diffsync.MARKERS.cell}"

        path = @current_pathname()

        path_prefix = path
        if path_prefix != ''
            path_prefix += '/'

        @container.find(".project-search-output-command").text(cmd)
        if @project.location?.path?
            @container.find(".project-search-output-path").text(@project.location.path + '/' + path)
        else
            @container.find(".project-search-output-path").text('')

        spinner = @container.find(".project-search-spinner")
        timer = setTimeout(( () -> spinner.show().spin()), 300)
        that = @
        salvus_client.exec
            project_id : @project.project_id
            command    : cmd + " | cut -c 1-256"  # truncate horizontal line length (imagine a binary file that is one very long line)
            timeout    : 10   # how long grep runs on client
            network_timeout : 15   # how long network call has until it must return something or get total error.
            max_output : max_output
            bash       : true
            err_on_exit: true
            path       : path
            cb         : (err, output) =>
                clearTimeout(timer)
                spinner.spin(false).hide()
                if (err and not output?) or (output? and not output.stdout?)
                    search_output.append($("<div>").text("Search took too long; please try a more restrictive search."))
                    return
                search_result = templates.find(".project-search-result")
                num_results = 0
                results = output.stdout.split('\n')
                if output.stdout.length >= max_output or results.length > max_results or err
                    @container.find(".project-search-output-further-results").show()
                else
                    @container.find(".project-search-output-further-results").hide()
                for line in results
                    if line.trim() == ""
                        continue
                    i = line.indexOf(":")
                    num_results += 1
                    if i == -1
                        # the find part
                        filename = line
                        r = search_result.clone()
                        r.find("a").text(filename).data(filename: path_prefix + filename).mousedown (e) ->
                            that.open_file(path:$(@).data('filename'), foreground:not(e.which==2 or e.ctrlKey))
                            return false
                        r.find("span").addClass('lighten').text('(filename)')
                    else
                        # the rgrep part
                        filename = line.slice(0,i)
                        context = line.slice(i+1)
                        # strip codes in worksheet output
                        if context.length > 0 and context[0] == diffsync.MARKERS.output
                            i = context.slice(1).indexOf(diffsync.MARKERS.output)
                            context = context.slice(i+2,context.length-1)
                        r = search_result.clone()
                        r.find("span").text(context)
                        r.find("a").text(filename).data(filename: path_prefix + filename).mousedown (e) ->
                            that.open_file(path:$(@).data('filename'), foreground:not(e.which==2 or e.ctrlKey))
                            return false

                    search_output.append(r)
                    if num_results >= max_results
                        break



    ########################################
    # ...?
    ########################################


    command_line_exec: () =>
        elt = @container.find(".project-command-line")
        input = elt.find("input")
        command0 = input.val()
        command = command0 + "\necho $HOME `pwd`"
        input.val("")
        @container?.find(".project-command-line-output").show()
        t = setTimeout((() => @container.find(".project-command-line-spinner").show().spin()), 300)
        salvus_client.exec
            project_id : @project.project_id
            command    : command
            timeout    : 15
            max_output : 100000
            bash       : true
            path       : @current_pathname()
            cb         : (err, output) =>
                clearTimeout(t)
                @container.find(".project-command-line-spinner").spin(false).hide()
                if err
                    alert_message(type:'error', message:"#{command0} -- #{err}")
                else
                    # All this code below is to find the current path
                    # after the command is executed, and also strip
                    # the output of "pwd" from the output:
                    j = i = output.stdout.length-2
                    while i>=0 and output.stdout[i] != '\n'
                        i -= 1
                    last = output.stdout.slice(i+1, j+1)
                    k = last.indexOf(' ')
                    home = last.slice(0,k)
                    cwd = last.slice(k+1)
                    if cwd.slice(0,home.length) == home
                        cwd = cwd.slice(home.length)
                        k = cwd.indexOf('/')
                        if k != -1
                            cwd = cwd.slice(k+1)
                            if @project.location?.path?
                                path = @project.location.path
                            else
                                path = ''
                            if path == '.'   # not good for our purposes here.
                                path = ''
                            if path == cwd.slice(0, path.length)
                                cwd = cwd.slice(path.length)
                                while cwd[0] == '/'
                                    cwd = cwd.slice(1)
                                if cwd.length > 0
                                    @current_path = cwd.split('/')
                                else
                                    @current_path = []
                        else
                            # root of project
                            @current_path = []

                        output.stdout = if i == -1 then "" else output.stdout.slice(0,i)

                    stdout = $.trim(output.stdout)
                    stderr = $.trim(output.stderr)
                    # We display the output of the command (or hide it)
                    if stdout
                        elt.find(".project-command-line-stdout").text(stdout).show()
                    else
                        elt.find(".project-command-line-stdout").hide()
                    if stderr
                        elt.find(".project-command-line-stderr").text(stderr).show()
                    else
                        elt.find(".project-command-line-stderr").hide()
                @update_file_list_tab(true)

    # command_line_tab_complete: () =>
    #     elt = @container.find(".project-command-line")
    #     input = elt.find("input")
    #     cmd = input.val()
    #     i = input.caret()
    #     while i>=0
    #         if /\s/g.test(cmd[i])  # is whitespace
    #             break
    #         i -= 1
    #     symbol = cmd.slice(i+1)

    #     # Here we do the actual completion.  This is very useless
    #     # naive for now.  However, we will later implement 100% full
    #     # bash completion on the VM host using pexpect (!).
    #     if not @_last_listing?
    #         return

    hide_tabs: () =>
        @container.find(".project-pages").hide()

    show_tabs: () =>
        @container.find(".project-pages").show()

    init_tabs: () ->
        @tabs = []
        that = @
        for item in @container.find(".project-pages").children()
            t = $(item)
            target = t.find("a").data('target')
            if not target?
                continue

            # activate any a[href=...] links elsewhere on the page
            @container.find("a[href=##{target}]").data('item',t).data('target',target).click () ->
                link = $(@)
                if link.data('item').hasClass('disabled')
                    return false
                that.display_tab(link.data('target'))
                return false

            t.find('a').tooltip(delay:{ show: 1000, hide: 200 })
            name = target
            tab = {label:t, name:name, target:@container.find(".#{name}")}
            @tabs.push(tab)

            t.find("a").data('item',t).click () ->
                link = $(@)
                if link.data('item').hasClass('disabled')
                    return false
                that.display_tab(link.data("target"))
                return false

            that.update_file_list_tab()
            if name == "project-file-listing"
                tab.onshow = () ->
                    that.update_file_list_tab()
            else if name == "project-editor"
                tab.onshow = () ->
                    that.editor.onshow()
            else if name == "project-new-file"
                tab.onshow = () ->
                    that.push_state('new/' + that.current_path.join('/'))
                    that.show_new_file_tab()
            else if name == "project-activity"
                tab.onshow = () =>
                    that.push_state('log')
                    @render_project_activity_log()
                    if not IS_MOBILE
                        @container.find(".salvus-project-activity-search").focus()

            else if name == "project-settings"
                tab.onshow = () ->
                    that.push_state('settings')
                    that.update_topbar()
                    #that.update_linked_projects()
                    that.update_collaborators()

            else if name == "project-search"
                tab.onshow = () ->
                    that.push_state('search/' + that.current_path.join('/'))
                    that.container.find(".project-search-form-input").focus()

        @display_tab("project-file-listing")

    create_editor: (initial_files) =>   # initial_files (optional)
        @editor = new Editor
            project_page  : @
            counter       : @container.find(".project-editor-file-count")
            initial_files : initial_files
        @container.find(".project-editor").append(@editor.element)

    display_tab: (name) =>
        @container.find(".project-pages").children().removeClass('active')
        @container.css(position: 'absolute')
        for tab in @tabs
            if tab.name == name
                @current_tab = tab
                tab.target.show()
                tab.label.addClass('active')
                tab.onshow?()
                @focus()
            else
                tab.target.hide()
        @editor?.resize_open_file_tabs()


    save_browser_local_data: (cb) =>
        @editor.save(undefined, cb)

    new_file_dialog: () =>
        salvus_client.write_text_file_to_project
            project_id : @project.project_id,
            path       : 'new_file.txt',
            content    : 'This is a new file.\nIt has little content....'
            cb         : (err, mesg) ->
                if err
                    alert_message(type:"error", message:"Connection error.")
                else if mesg.event == "error"
                    alert_message(type:"error", message:mesg.error)
                else
                    alert_message(type:"success", message: "New file created.")

    new_file: (path) =>
        salvus_client.write_text_file_to_project
            project_id : @project.project_id
            path       : "#{path}/untitled"
            content    : ""
            cb : (err, mesg) =>
                if err
                    alert_message(type:"error", message:"Connection error.")
                else if mesg.event == "error"
                    alert_message(type:"error", message:mesg.error)
                else
                    alert_message(type:"success", message: "New file created.")
                    @update_file_list_tab()

    load_from_server: (opts) ->
        opts = defaults opts,
            project_id : required
            cb         : undefined

        salvus_client.get_project
            cb : (error, project) =>
                if error
                    opts.cb?(error)
                else
                    @project = project
                    @update_view()
                    opts.cb?()

    save_to_server: (opts) ->
        opts = defaults opts,
            timeout : 10

        salvus_client.update_project_data
            data    : @project
            cb      : opts.cb
            timeout : opts.timeout

    update_topbar: () ->
        if not @project?
            return

        if @project.public
            @container.find(".project-public").show()
            @container.find(".project-private").hide()
            @container.find(".project-heading-well").removeClass("private-project").addClass("public-project")
            @container.find(".project-settings-make-public").hide()
            @container.find(".project-settings-make-private").show()
        else
            @container.find(".project-public").hide()
            @container.find(".project-private").show()
            @container.find(".project-heading-well").addClass("private-project").removeClass("public-project")
            @container.find(".project-settings-make-public").show()
            @container.find(".project-settings-make-private").hide()


        @container.find(".project-project_title").text(@project.title)
        @container.find(".project-project_description").text(@project.description)

        label = @project.title.slice(0,MAX_TITLE_LENGTH) + if @project.title.length > MAX_TITLE_LENGTH then "..." else ""
        top_navbar.set_button_label(@project.project_id, label)
        document.title = "Sagemath: #{@project.title}"

        if not (@_computing_usage? and @_computing_usage)
            usage = @container.find(".project-disk_usage")
            # --exclude=.sagemathcloud --exclude=.forever --exclude=.node* --exclude=.npm --exclude=.sage
            @_computing_usage = true
            salvus_client.exec
                project_id : @project.project_id
                command    : 'df -h $HOME'
                bash       : true
                timeout    : 30
                cb         : (err, output) =>
                    delete @_computing_usage
                    if not err
                        #usage.text(output.stdout.split('\t')[0])
                        o = output.stdout.split('\n')[1].split(/\s+/)
                        usage.show()
                        usage.find(".salvus-usage-size").text(o[1])
                        usage.find(".salvus-usage-used").text(o[2])
                        usage.find(".salvus-usage-avail").text(o[3])
                        usage.find(".salvus-usage-percent").text(o[4])

        return @



    # Return the string representation of the current path, as a
    # relative path from the root of the project.
    current_pathname: () => @current_path.join('/')

    # Set the current path array from a path string to a directory
    set_current_path: (path) =>
        if path == "" or not path?
            @current_path = []
        else
            if path.length > 0 and path[path.length-1] == '/'
                path = path.slice(0,path.length-1)
            @current_path = path.split('/')
        @container.find(".project-file-top-current-path-display").text(path)

    # Render the slash-separated and clickable path that sits above
    # the list of files (or current file)
    update_current_path: () =>
        @container.find(".project-file-top-current-path-display").text(@current_pathname())

        t = @container.find(".project-file-listing-current_path")
        t.empty()
        if @current_path.length == 0
            return

        t.append($("<a class=project-file-listing-path-segment-link>").html(template_home_icon.clone().click(() =>
            @current_path=[]; @update_file_list_tab())))

        new_current_path = []
        that = @
        for segment in @current_path
            new_current_path.push(segment)
            t.append(template_segment_sep.clone())
            t.append($("<a class=project-file-listing-path-segment-link>"
            ).text(segment
            ).data("current_path",new_current_path[..]  # [..] means "make a copy"
            ).click((elt) =>
                @current_path = $(elt.target).data("current_path")
                @update_file_list_tab()
            ))


    focus: () =>
        if not IS_MOBILE  # do *NOT* do on mobile, since is very annoying to have a keyboard pop up.
            switch @current_tab.name
                when "project-file-listing"
                    @container.find(".salvus-project-search-for-file-input").focus()
                when "project-editor"
                    @editor.focus()

    init_dropzone_upload: () =>
        # Dropzone
        uuid = misc.uuid()
        dz_container = @container.find(".project-dropzone")
        dz_container.empty()
        dz = $('<div class="dropzone"></div>')
        if IS_MOBILE
            dz.append($('<span class="message" style="font-weight:bold;font-size:14pt">Tap to select files to upload</span>'))
        dz_container.append(dz)
        dest_dir = encodeURIComponent(@new_file_tab.find(".project-new-file-path").text())
        dz.dropzone
            url: window.salvus_base_url + "/upload?project_id=#{@project.project_id}&dest_dir=#{dest_dir}"
            maxFilesize: 128 # in megabytes

    init_new_file_tab: () =>

        # Make it so clicking on each of the new file tab buttons does the right thing.
        @new_file_tab = @container.find(".project-new-file")
        @new_file_tab_input = @new_file_tab.find(".project-new-file-path-input")
        @new_file_tab.find("a").tooltip()

        path = (ext) =>
            name = $.trim(@new_file_tab_input.val())
            if name.length == 0
                return ''
            s = $.trim(@new_file_tab.find(".project-new-file-path").text() + name)
            if ext?
                if misc.filename_extension(s) != ext
                    s += '.' + ext
            return s

        create_terminal = () =>
            p = path('term')
            if p.length == 0
                @new_file_tab_input.focus()
                return false
            @display_tab("project-editor")
            tab = @editor.create_tab(filename:p, content:"")
            @editor.display_tab(path:p)
            return false

        @new_file_tab.find("a[href=#new-terminal]").click(create_terminal)

        @new_file_tab.find("a[href=#new-worksheet]").click () =>
            create_file('sagews')
            return false

        @new_file_tab.find("a[href=#new-latex]").click () =>
            create_file('tex')
            return false

        @new_file_tab.find("a[href=#new-ipython]").click () =>
            create_file('ipynb')
            return false

        BANNED_FILE_TYPES = ['doc', 'docx', 'pdf', 'sws']

        create_file = (ext) =>
            p = path(ext)
            ext = misc.filename_extension(p)

            if ext == 'term'
                create_terminal()
                return false

            if ext in BANNED_FILE_TYPES
                alert_message(type:"error", message:"Creation of #{ext} files not supported.", timeout:3)
                return false

            if p.length == 0
                @new_file_tab_input.focus()
                return false
            if p[p.length-1] == '/'
                create_folder()
                return false
            salvus_client.exec
                project_id : @project.project_id
                command    : "new-file"
                timeout    : 10
                args       : [p]
                err_on_exit: true
                cb         : (err, output) =>
                    if err
                        alert_message(type:"error", message:"#{output?.stdout} #{output?.stderr} #{err}")
                    else
                        alert_message(type:"info", message:"Created new file '#{p}'")
                        @display_tab("project-editor")
                        tab = @editor.create_tab(filename:p, content:"")
                        @editor.display_tab(path:p)
            return false

        create_folder = () =>
            p = path()
            if p.length == 0
                @new_file_tab_input.focus()
                return false
            @ensure_directory_exists
                path : p
                cb   : (err) =>
                    if not err
                        alert_message(type:"info", message:"Made directory '#{p}'")
                        for segment in @new_file_tab_input.val().split('/')
                            if segment.length > 0
                                @current_path.push(segment)
                        @display_tab("project-file-listing")
            return false

        click_new_file_button = () =>
            target = @new_file_tab_input.val()
            if target.indexOf("://") != -1 or misc.startswith(target, "git@github.com:")
                download_button.icon_spin(start:true, delay:500)
                new_file_from_web target, () =>
                    download_button.icon_spin(false)

            else
                create_file()
            return false

        @new_file_tab.find("a[href=#new-file]").click(click_new_file_button)

        download_button = @new_file_tab.find("a[href=#new-download]").click(click_new_file_button)

        @new_file_tab.find("a[href=#new-folder]").click(create_folder)
        @new_file_tab_input.keyup (event) =>
            if event.keyCode == 13
                click_new_file_button()
                return false
            if (event.metaKey or event.ctrlKey) and event.keyCode == 79     # control-o
                @display_tab("project-file-listing")
                return false

        new_file_from_web = (url, cb) =>
            dest = @new_file_tab.find(".project-new-file-path").text()
            long = () ->
                if dest == ""
                    d = "root of project"
                else
                    d = dest
                alert_message(type:'info', message:"Downloading '#{url}' to '#{d}', which may run for up to 15 seconds.")
            timer = setTimeout(long, 3000)
            @get_from_web
                url     : url
                dest    : dest
                timeout : 15
                alert   : true
                cb      : (err) =>
                    clearTimeout(timer)
                    if not err
                        alert_message(type:'info', message:"Finished downloading '#{url}' to '#{dest}'.")
                    cb?(err)
            return false

    show_new_file_tab: () =>
        # Update the path
        path = @current_pathname()
        if path != ""
            path += "/"
        @new_file_tab.find(".project-new-file-path").text(path)
        @init_dropzone_upload()

        elt = @new_file_tab.find(".project-new-file-if-root")
        if path != ''
            elt.hide()
        else
            elt.show()

        # Clear the filename and focus on it
        now = misc.to_iso(new Date()).replace('T','-').replace(/:/g,'')
        @new_file_tab_input.val(now)
        if not IS_MOBILE
            @new_file_tab_input.focus().select()

    update_snapshot_ui_elements: () =>
        # nothing special to do
        return

    chdir: (path, no_focus) =>
        @set_current_path(path)
        @update_file_list_tab(no_focus)

    switch_to_directory: (new_path) =>
        @current_path = new_path
        @update_file_list_tab()

    # Update the listing of files in the current_path, or display of the current file.
    update_file_list_tab: (no_focus) =>

        spinner = @container.find(".project-file-listing-spinner")
        timer = setTimeout( (() -> spinner.show().spin()), 100 )

        # TODO: ** must change this -- do *not* set @current_path until we get back the correct listing!!!!

        path = @current_path.join('/')

        url_path = path
        if url_path.length > 0 and url_path[path.length-1] != '/'
            url_path += '/'
        @push_state('files/' + url_path)

        #console.log("path = ", path)
        salvus_client.project_directory_listing
            project_id : @project.project_id
            path       : path
            time       : @_sort_by_time
            hidden     : @container.find("a[href=#hide-hidden]").is(":visible")
            cb         : (err, listing) =>

                if listing?.real_path?
                    @set_current_path(listing.real_path)
                    @push_state('files/' + listing.real_path)

                clearTimeout(timer)
                spinner.spin(false).hide()

                # Update the display of the path above the listing or file preview
                @update_current_path()

                # Update UI options that change as a result of browsing snapshots.
                @update_snapshot_ui_elements()

                @container.find("a[href=#empty-trash]").toggle(@current_path[0] == '.trash')
                @container.find("a[href=#trash]").toggle(@current_path[0] != '.trash')

                if (err)
                    console.log("update_file_list_tab: error -- ", err)
                    if @_last_path_without_error? and @_last_path_without_error != path
                        #console.log("using last path without error:  ", @_last_path_without_error)
                        @set_current_path(@_last_path_without_error)
                        @_last_path_without_error = undefined # avoid any chance of infinite loop
                        @update_file_list_tab(no_focus)
                    else
                        # just try again in a bit.
                        setTimeout((()=>@update_file_list_tab(no_focus)), 3000)
                        #alert_message(type:"error", message:"Error viewing files at '#{path}' in project '#{@project.title}'.")
                    return

                # remember for later
                @_last_path_without_error = path

                if not listing?
                    return

                @_last_listing = listing

                # Now rendering the listing or file preview
                file_or_listing = @container.find(".project-file-listing-file-list")
                file_or_listing.empty()
                directory_is_empty = true

                # The path we are viewing.
                path = @current_pathname()

                @container.find(".project-file-tools a").removeClass("disabled")

                # Show the command prompt
                # @container.find("span.project-command-line").show().find("pre").hide()

                # Hide the edit button
                @container.find(".project-file-tools a[href=#edit]").addClass("disabled")

                # Hide the move and delete buttons if and only if this is the top level path
                if path == ""
                    @container.find(".project-file-tools a[href=#move]").addClass("disabled")
                    @container.find(".project-file-tools a[href=#delete]").addClass("disabled")

                that = @

                file_dropped_on_directory = (event, ui) ->
                    src = ui.draggable.data('name')
                    if not src?
                        return
                    dest = $(@).data('name')
                    that.move_file
                        src  : src
                        dest : dest
                        cb   : (err) =>
                            if not err
                                that.update_file_list_tab(true)

                if that.current_path.length > 0
                    # Create special link to the parent directory
                    t = template_project_directory.clone()
                    parent = that.current_path.slice(0, that.current_path.length-1).join('/')
                    if parent == ""
                        parent = "."
                    t.data('name', parent)
                    t.find(".project-directory-name").html("<i class='fa fa-reply'> </i> Parent Directory")
                    t.find("input").hide()  # hide checkbox, etc.
                    # Clicking to open the directory
                    t.click () ->
                        that.current_path.pop()
                        that.update_file_list_tab()
                        return false
                    t.droppable(drop:file_dropped_on_directory, scope:'files')
                    t.find("a").tooltip(trigger:'hover', delay: { show: 500, hide: 100 }); t.find(".fa-move").tooltip(trigger:'hover', delay: { show: 500, hide: 100 })
                    file_or_listing.append(t)

                # Show the files
                for obj in listing['files']
                    if obj.isdir? and obj.isdir
                        if obj.snapshot?
                            t = template_project_directory_snapshot.clone()
                            if obj.snapshot == ''
                                t.find(".btn").hide()
                        else
                            t = template_project_directory.clone()
                            t.droppable(drop:file_dropped_on_directory, scope:'files')
                        t.find(".project-directory-name").text(obj.name)
                    else
                        if obj.snapshot?
                            t =  template_project_file_snapshot.clone()
                            if obj.snapshot == ''
                                t.find(".btn").hide()
                        else
                            t = template_project_file.clone()
                        if obj.name.indexOf('.') != -1
                            ext = filename_extension(obj.name)
                            name = obj.name.slice(0,obj.name.length - ext.length - 1)
                        else
                            ext = ''
                            name = obj.name
                        t.find(".project-file-name").text(name)
                        if ext != ''
                            t.find(".project-file-name-extension").text('.' + ext)
                            if file_associations[ext]? and file_associations[ext].icon?
                                t.find(".project-file-icon").removeClass("fa-file").addClass(file_associations[ext].icon)
                        if obj.mtime?
                            date = (new Date(obj.mtime*1000)).toISOString()
                            t.find(".project-file-last-mod-date").attr('title', date).timeago()
                        if obj.size?
                            t.find(".project-file-size").text(human_readable_size(obj.size))
                        if obj.commit?.date?
                            date = (new Date(obj.commit.date*1000)).toISOString()
                            t.find(".project-file-last-commit-date").attr('title', date).timeago()
                        else
                            t.find(".project-file-last-commit-date-container").hide()
                        if obj.commit?.message?
                            t.find(".project-file-last-commit-message").text(trunc(obj.commit.message, 70))
                    #end if

                    # Define file actions using a closure
                    @_init_listing_actions(t, path, obj.name, obj.fullname, obj.isdir? and obj.isdir, obj.snapshot?)

                    # Drag handle for moving files via drag and drop.
                    handle = t.find(".project-file-drag-handle")
                    handle.click () =>
                        # do not want clicking on the handle to open the file.
                        return false
                    t.draggable
                        handle         : handle
                        zIndex         : 100
                        opacity        : 0.75
                        revertDuration : 200
                        revert         : "invalid"
                        axis           : 'y'
                        scope          : 'files'

                    t.find("a").tooltip(trigger:'hover', delay: { show: 500, hide: 100 }); t.find(".fa-move").tooltip(trigger:'hover', delay: { show: 500, hide: 100 })
                    # Finally add our new listing entry to the list:
                    directory_is_empty = false
                    file_or_listing.append(t)

                #@clear_file_search()
                @update_file_search()

                # No files
                if directory_is_empty and path != ".trash" and path.slice(0,9) != ".snapshot"
                    @container.find(".project-file-listing-no-files").show()
                else
                    @container.find(".project-file-listing-no-files").hide()

                if no_focus? and no_focus
                    return
                @focus_file_search()

    _init_listing_actions: (t, path, name, fullname, isdir, is_snapshot) =>
        if not fullname?
            if path != ""
                fullname = path + '/' + name
            else
                fullname = name

        t.data('name', fullname)  # save for other uses outside this function

        b = t.find(".project-file-buttons")

        open = (e) =>
            if isdir
                @set_current_path(fullname)
                @update_file_list_tab()
            else
                @open_file
                    path : fullname
                    foreground : not(e.which==2 or e.ctrlKey)
            return false

        file_link = t.find("a[href=#open-file]")

        if not (is_snapshot or isdir)
            # Opening a file
            file_link.mousedown(open)

            # Clicking on link -- open the file
            # do not use t.mousedown here, since that breaks the download, etc., links.
            t.click(open)

        if isdir
            t.find("a[href=#open-file]").click(open)

        if is_snapshot
            restore = () =>
                n = fullname.slice(".snapshot/xxxx-xx-xx/".length)
                i = n.indexOf('/')
                if i != -1
                    snapshot = n.slice(0,i)
                    path = n.slice(i+1)
                else
                    snapshot = n
                    path = '.'
                m = "Are you sure you want to <b>overwrite</b> '#{path}' with the version from #{snapshot}?  Any modified overwritten files will be moved to the trash before being overwritten."
                bootbox.confirm m, (result) =>
                    if result
                        alert_message
                            type    : "info"
                            timeout : 3
                            message : "Restoring '#{snapshot}/#{path}'... (this can take a few minutes)"
                        salvus_client.call
                            message:
                                message.snap
                                    command    : 'restore'
                                    project_id : @project.project_id
                                    snapshot   : snapshot
                                    path       : path
                                    timeout    : 1800
                            timeout :
                                1800
                            cb : (err, resp) =>
                                if err or resp.event == 'error'
                                    alert_message(type:"error", message:"Error restoring '#{path}'")
                                else
                                    x = path.split('/')
                                    @current_path = x.slice(0, x.length-1)
                                    @update_file_list_tab()
                                    alert_message(type:"success", message:"Restored '#{path}' from #{snapshot}.")

                return false

            t.find("a[href=#restore]").click(restore)

            # This is temporary -- open-file should show a preview and changelog, but that will
            # take some time to implement.
            if not isdir
                t.find("a[href=#open-file]").click(restore)

            return

        # Show project file buttons on hover only
        if not IS_MOBILE
            t.hover( (() -> b.show()) ,  (() -> b.hide()))

        # Downloading a file
        dl = b.find("a[href=#download-file]")
        dl.click () =>
            dl.find(".spinner").show()
            @download_file
                path : fullname
                cb   : () =>
                    dl.find(".spinner").hide()
            return false

        # Deleting a file
        del = b.find("a[href=#delete-file]")
        del.click () =>
            del.find(".spinner").show()
            @trash_file
                path : fullname
                cb   : () =>
                    del.find(".spinner").hide()
            return false

        copy = b.find("a[href=#copy-file]")
        copy.click () =>
            @copy_file(fullname)
            return false

        # Renaming a file
        rename_link = t.find('a[href=#rename-file]')

        rename_link.click () =>
            @click_to_rename_file(path, file_link)
            return false

    copy_file:  (path, cb) =>
        dialog = $(".project-copy-file-dialog").clone()
        dialog.modal()
        new_dest = undefined
        new_src = undefined
        async.series([
            (cb) =>
                if path.slice(0,5) == '.zfs/'
                    dest = path.slice('.zfs/snapshot/2013-12-31T22:32:30/'.length)
                else
                    dest = path
                dialog.find(".copy-file-src").val(path)
                dialog.find(".copy-file-dest").val(dest).focus()
                submit = (ok) =>
                    dialog.modal('hide')
                    if ok
                        new_src = dialog.find(".copy-file-src").val()
                        new_dest = dialog.find(".copy-file-dest").val()
                    cb()
                    return false
                dialog.find(".btn-close").click(()=>submit(false))
                dialog.find(".btn-submit").click(()=>submit(true))
            (cb) =>
                if not new_dest?
                    cb(); return
                alert_message(type:'info', message:"Copying #{new_src} to #{new_dest}...")
                salvus_client.exec
                    project_id : @project.project_id
                    command    : 'rsync'
                    args       : ['-axH', '--backup', '--backup-dir=.trash/', new_src, new_dest]
                    timeout    : 60   # how long grep runs on client
                    network_timeout : 75   # how long network call has until it must return something or get total error.
                    err_on_exit: true
                    path       : '.'
                    cb         : (err, output) =>
                        if err
                            alert_message(type:"error", message:"Error copying #{new_src} to #{new_dest} -- #{output.stderr}")
                        else
                            alert_message(type:"success", message:"Successfully copied #{new_src} to #{new_dest}")
                            @update_file_list_tab()
                        cb(err)
        ], (err) => cb?(err))


    click_to_rename_file: (path, link) =>
        if link.attr('contenteditable')
            # already done.
            return
        link.attr('contenteditable',true)
        link.focus()
        original_name = link.text()
        link.text(original_name)
        doing_rename = false
        rename = () =>
            if doing_rename
                return
            new_name = link.text()
            if original_name != new_name
                doing_rename = true
                @rename_file(path, original_name, new_name)
                return false

        # Capture leaving box
        link.on 'blur', rename

        # Capture pressing enter
        link.keydown (evt) ->
            if evt.keyCode == 13
                rename()
                return false

        return false


    rename_file: (path, original_name, new_name) =>
        @move_file
            src : original_name
            dest : new_name
            path : path
            cb   : (err) =>
                if not err
                    @update_file_list_tab(true)

    move_file: (opts) =>
        opts = defaults opts,
            src   : required
            dest  : required
            path  : undefined   # default to root of project
            cb    : undefined   # cb(true or false)
            mv_args : undefined
            alert : true        # show alerts
        args = [opts.src, opts.dest]
        if opts.mv_args?
            args = args.concat(opts.mv_args)
        salvus_client.exec
            project_id : @project.project_id
            command    : 'mv'
            args       : args
            timeout    : 5  # move should be fast..., unless across file systems.
            network_timeout : 10
            err_on_exit : false
            path       : opts.path
            cb         : (err, output) =>
                if opts.alert
                    if err
                        alert_message(type:"error", message:"Communication error while moving '#{opts.src}' to '#{opts.dest}' -- #{err}")
                    else if output.event == 'error'
                        alert_message(type:"error", message:"Error moving '#{opts.src}' to '#{opts.dest}' -- #{output.error}")
                    else
                        alert_message(type:"info", message:"Moved '#{opts.src}' to '#{opts.dest}'")
                opts.cb?(err or output.event == 'error')

    ensure_directory_exists: (opts) =>
        opts = defaults opts,
            path  : required
            cb    : undefined  # cb(true or false)
            alert : true
        salvus_client.exec
            project_id : @project.project_id
            command    : "mkdir"
            timeout    : 15
            args       : ['-p', opts.path]
            cb         : (err, result) =>
                if opts.alert
                    if err
                        alert_message(type:"error", message:err)
                    else if result.event == 'error'
                        alert_message(type:"error", message:result.error)
                opts.cb?(err or result.event == 'error')

    ensure_file_exists: (opts) =>
        opts = defaults opts,
            path  : required
            cb    : undefined  # cb(true or false)
            alert : true

        async.series([
            (cb) =>
                dir = misc.path_split(opts.path).head
                if dir == ''
                    cb()
                else
                    @ensure_directory_exists(path:dir, alert:opts.alert, cb:cb)
            (cb) =>
                #console.log("ensure_file_exists -- touching '#{opts.path}'")
                salvus_client.exec
                    project_id : @project.project_id
                    command    : "touch"
                    timeout    : 15
                    args       : [opts.path]
                    cb         : (err, result) =>
                        if opts.alert
                            if err
                                alert_message(type:"error", message:err)
                            else if result.event == 'error'
                                alert_message(type:"error", message:result.error)
                        opts.cb?(err or result.event == 'error')
        ], (err) -> opts.cb?(err))

    get_from_web: (opts) =>
        opts = defaults opts,
            url     : required
            dest    : undefined
            timeout : 10
            alert   : true
            cb      : undefined     # cb(true or false, depending on error)

        {command, args} = transform_get_url(opts.url)

        salvus_client.exec
            project_id : @project.project_id
            command    : command
            timeout    : opts.timeout
            path       : opts.dest
            args       : args
            cb         : (err, result) =>
                if opts.alert
                    if err
                        alert_message(type:"error", message:err)
                    else if result.event == 'error'
                        alert_message(type:"error", message:result.error)
                opts.cb?(err or result.event == 'error')

    visit_trash: () =>
        @ensure_directory_exists
            path:'.trash'
            cb: (err) =>
                if not err
                    @current_path = ['.trash']
                    @update_file_list_tab()

    init_refresh_files: () =>
        @container.find("a[href=#refresh-listing]").tooltip(delay:{ show: 500, hide: 100 }).click () =>
            @update_file_list_tab()
            return false

    init_hidden_files_icon: () =>
        elt = @container.find(".project-hidden-files")
        elt.find("a").tooltip(delay:{ show: 500, hide: 100 }).click () =>
            elt.find("a").toggle()
            @update_file_list_tab()
            return false

    init_sort_files_icon: () =>
        elt = @container.find(".project-sort-files")
        @_sort_by_time = local_storage(@project.project_id, '', 'sort_by_time')
        if not @_sort_by_time
            @_sort_by_time = true
        if @_sort_by_time
            elt.find("a").toggle()
        elt.find("a").tooltip(delay:{ show: 500, hide: 100 }).click () =>
            elt.find("a").toggle()
            @_sort_by_time = elt.find("a[href=#sort-by-time]").is(":visible")
            local_storage(@project.project_id, '', 'sort_by_time', @_sort_by_time)
            @update_file_list_tab()
            return false

    init_project_activity: () =>
        page = @container.find(".project-activity")
        page.find("h1").icon_spin(start:true, delay:500)
        @_project_activity_log = page.find(".project-activity-log")
        if window.salvus_base_url
            LOG_FILE = '.sagemathcloud-local.log'
        else
            LOG_FILE = '.sagemathcloud.log'

        @container.find(".salvus-project-activity-search").keyup () =>
            @_project_activity_log_page = 0
            @render_project_activity_log()

        @container.find(".salvus-project-activity-search-clear").click () =>
            @container.find(".salvus-project-activity-search").val('')
            @_project_activity_log_page = 0
            @render_project_activity_log()

        async.series([
            (cb) =>
                @ensure_file_exists
                    path  : LOG_FILE
                    alert : false
                    cb    : cb

            (cb) =>
                require('syncdoc').synchronized_string
                    project_id : @project.project_id
                    filename   : LOG_FILE
                    cb         : (err, doc) =>
                        @project_log = doc
                        cb(err)

            (cb) =>
                log_output = page.find(".project-activity-log")
                @project_log.on 'sync', () =>
                    @render_project_activity_log()

                @project_activity({event:'open_project'})

                chat_input = page.find(".project-activity-chat")
                chat_input.keydown (evt) =>
                    if evt.which == 13 and not evt.shiftKey
                        mesg = $.trim(chat_input.val())
                        if mesg
                            @project_activity({event:'chat', mesg:mesg})
                            chat_input.val('')
                        return false

                @_project_activity_log_page = 0
                page.find(".project-activity-newer").click () =>
                    if page.find(".project-activity-newer").hasClass('disabled')
                        return false
                    @_project_activity_log_page -= 1
                    page.find(".project-activity-older").removeClass('disabled')
                    if @_project_activity_log_page < 0
                        @_project_activity_log_page = 0
                    else
                        @render_project_activity_log()
                    if @_project_activity_log_page == 0
                        page.find(".project-activity-newer").addClass('disabled')
                    return false

                page.find(".project-activity-older").click () =>
                    if page.find(".project-activity-older").hasClass('disabled')
                        return false
                    @_project_activity_log_page += 1
                    page.find(".project-activity-newer").removeClass('disabled')
                    @render_project_activity_log()
                    return false

                cb()

        ], (err) =>
            page.find("h1").icon_spin(false)
            if err
                # Just try again with exponential backoff  This can and does fail if say the project is first being initailized.
                if not @_init_project_activity?
                    @_init_project_activity = 3000
                else
                    @_init_project_activity = Math.min(1.3*@_init_project_activity, 60000)

                setTimeout((() => @init_project_activity()), @_init_project_activity)
            else
                @_init_project_activity = undefined
        )

    project_activity: (mesg, delay) =>
        if @project_log?
            #console.log("project_activity", mesg)
            mesg.fullname   = account.account_settings.fullname()
            mesg.account_id = account.account_settings.account_id()
            s = misc.to_json(new Date())
            mesg.date = s.slice(1, s.length-1)
            @project_log.live(@project_log.live() + '\n' + misc.to_json(mesg))
            @render_project_activity_log()
            @project_log.save()
        else
            if not delay?
                delay = 300
            else
                delay = Math.min(15000, delay*1.3)
            f = () =>
                @project_activity(mesg, delay)
            setTimeout(f, delay)

    render_project_activity_log: () =>
        if not @project_log? or @current_tab?.name != 'project-activity'
            return
        log = @project_log.live()
        if @_render_project_activity_log_last? and @_render_project_activity_log == log
            return
        else
            @_render_project_activity_log_last = log

        items_per_page = 30
        page = @_project_activity_log_page

        @_project_activity_log.html('')

        y = $.trim(@container.find(".salvus-project-activity-search").val())
        if y.length > 0
            search = (x.toLowerCase() for x in y.split(/[ ]+/))
        else
            search = []

        lines = log.split('\n')
        lines.reverse()
        start = page*items_per_page
        stop  = (page+1)*items_per_page

        if search.length > 0
            if search.length == 1
                s = search[0]
                f = (x) ->
                    x.toLowerCase().indexOf(s) != -1
            else
                f = (x) ->
                    y = x.toLowerCase()
                    for k in search
                        if y.indexOf(k) == -1
                            return false
                    return true
            z = []
            for x in lines
                if f(x)
                    z.push(x)
                    if z.length > stop
                        break
            lines = z

        lines = lines.slice(start, stop)

        template = $(".project-activity-templates")
        template_entry = template.find(".project-activity-entry")
        that = @

        if lines.length < items_per_page
            @container.find(".project-activity-older").addClass('disabled')
        else
            @container.find(".project-activity-older").removeClass('disabled')

        for e in lines
            if not $.trim(e)
                continue
            try
                entry = JSON.parse(e)
            catch
                entry = {event:'other'}

            elt = undefined
            switch entry.event
                when 'chat'
                    elt = template.find(".project-activity-chat").clone()
                    elt.find(".project-activity-chat-mesg").text(entry.mesg).mathjax()
                when 'open_project'
                    elt = template.find(".project-activity-open_project").clone()
                when 'open'
                    elt = template.find(".project-activity-open").clone()
                    f = (e) ->
                        filename = $(@).text()
                        if filename == ".sagemathcloud.log"
                            alert_message(type:"error", message:"Edit .sagemathcloud.log via the terminal (this is safe).")
                        else
                            that.open_file(path:filename, foreground: not(e.which==2 or e.ctrlKey))
                        return false
                    elt.find(".project-activity-open-filename").text(entry.filename).mousedown(f)
                    elt.find(".project-activity-open-type").text(entry.type)
                else
                    elt = template.find(".project-activity-other").clone()
                    elt.find(".project-activity-value").text(e)

            if elt?
                x = template_entry.clone()
                x.find(".project-activity-value").append(elt)
                if entry.fullname?
                    x.find(".project-activity-name").text(entry.fullname)
                else
                    x.find(".project-activity-name").hide()
                if entry.date?
                    try
                       x.find(".project-activity-date").attr('title',(new Date(entry.date)).toISOString()).timeago()
                    catch e
                       console.log("TODO: ignoring invalid project log time value -- #{entry.date}")
                else
                    x.find(".project-activity-date").hide()

                @_project_activity_log.append(x)


    init_project_download: () =>
        # Download entire project -- not implemented!
        ###
        link = @container.find("a[href=#download-project]")
        link.click () =>
            link.find(".spinner").show()
            @download_file
                path   : ""
                cb     : (err) =>
                    link.find(".spinner").hide()
            return false
        ###

    init_delete_project: () =>
        if @project.deleted
            @container.find(".project-settings-delete").hide()
            return
        else
            @container.find(".project-settings-delete").show()
        link = @container.find("a[href=#delete-project]")
        m = "<h4 style='color:red;font-weight:bold'><i class='fa-warning-sign'></i>  Delete Project</h4>Are you sure you want to delete this project?<br><br><span class='lighten'>You can always undelete the project later from the Projects tab.</span>"
        link.click () =>
            bootbox.confirm m, (result) =>
                if result
                    link.find(".spinner").show()
                    salvus_client.delete_project
                        project_id : @project.project_id
                        timeout    : 30
                        cb         : (err) =>
                            link.find(".spinner").hide()
                            if err
                                alert_message
                                    type : "error"
                                    message: "Error trying to delete project \"#{@project.title}\".   Please try again later. #{err}"
                            else
                                @close()
                                alert_message
                                    type : "info"
                                    message : "Successfully deleted project \"#{@project.title}\".  (If this was a mistake, you can undelete the project from the Projects tab.)"
                                    timeout : 5
            return false

    init_undelete_project: () =>

        if not @project.deleted
            @container.find(".project-settings-undelete").hide()
            return
        else
            @container.find(".project-settings-undelete").show()

        link = @container.find("a[href=#undelete-project]")

        m = "<h4 style='color:red;font-weight:bold'><i class='fa-warning-sign'></i>  Undelete Project</h4>Are you sure you want to undelete this project?"
        link.click () =>
            bootbox.confirm("Project move is temporarily disabled while we sort out some replication issues that can lead to data inavailability.  If you find that files seem to have vanished in the last few days, contact wstein@gmail.com; your files are there, just on a different machine.")
            return
            bootbox.confirm m, (result) =>
                if result
                    link.find(".spinner").show()
                    salvus_client.undelete_project
                        project_id : @project.project_id
                        timeout    : 10
                        cb         : (err) =>
                            link.find(".spinner").hide()
                            if err
                                alert_message
                                    type : "error"
                                    message: "Error trying to undelete project.  Please try again later. #{err}"
                            else
                                link.hide()
                                @container.find("a[href=#delete-project]").show()
                                alert_message
                                    type : "info"
                                    message : "Successfully undeleted project \"#{@project.title}\"."
            return false


    init_make_public: () =>
        link = @container.find("a[href=#make-public]")
        m = "<h4 style='color:red;font-weight:bold'><i class='fa-warning-sign'></i>  Make Public</h4>Are you sure you want to make this project public?"
        link.click () =>
            bootbox.confirm m, (result) =>
                if result
                    link.find(".spinner").show()
                    salvus_client.update_project_data
                        project_id : @project.project_id
                        data       : {public:true}
                        cb         : (err) =>
                            link.find(".spinner").hide()
                            if err
                                alert_message
                                    type : "error"
                                    message: "Error trying to make project public.  Please try again later. #{err}"
                            else
                                @reload_settings()
                                alert_message
                                    type : "info"
                                    message : "Successfully made project \"#{@project.title}\" public."
            return false

    init_make_private: () =>
        link = @container.find("a[href=#make-private]")
        m = "<h4 style='color:red;font-weight:bold'><i class='fa-warning-sign'></i>  Make Private</h4>Are you sure you want to make this project private?"
        link.click () =>
            bootbox.confirm m, (result) =>
                if result
                    link.find(".spinner").show()
                    salvus_client.update_project_data
                        project_id : @project.project_id
                        data       : {public:false}
                        cb         : (err) =>
                            link.find(".spinner").hide()
                            if err
                                alert_message
                                    type : "error"
                                    message: "Error trying to make project private.  Please try again later. #{err}"
                            else
                                @reload_settings()
                                alert_message
                                    type : "info"
                                    message : "Successfully made project \"#{@project.title}\" private."
            return false

    init_add_noncloud_collaborator: () =>
        button = @container.find(".project-add-noncloud-collaborator").find("a")
        button.click () =>
            dialog = $(".project-invite-noncloud-users-dialog").clone()
            query = @container.find(".project-add-collaborator-input").val()
            @container.find(".project-add-collaborator-input").val('')
            dialog.find("input").val(query)
            email = "Please collaborate with me using the SageMathCloud on '#{@project.title}'.\n\n    https://cloud.sagemath.com\n\n--\n#{account.account_settings.fullname()}"
            dialog.find("textarea").val(email)
            dialog.modal()
            submit = () =>
                dialog.modal('hide')
                salvus_client.invite_noncloud_collaborators
                    project_id : @project.project_id
                    to         : dialog.find("input").val()
                    email      : dialog.find("textarea").val()
                    cb         : (err, resp) =>
                        if err
                            alert_message(type:"error", message:err)
                        else
                            alert_message(message:resp.mesg)
                return false
            dialog.submit(submit)
            dialog.find("form").submit(submit)
            dialog.find(".btn-submit").click(submit)
            dialog.find(".btn-close").click(() -> dialog.modal('hide'); return false)
            return false

    init_move_project: () =>
        button = @container.find(".project-settings-move").find("a")
        button.click () =>
            #bootbox.confirm("Project move is temporarily disabled due to some synchronization issues that we are fixing right now.", (result) =>)
            #return false
            dialog = $(".project-move-dialog").clone()
            dialog.modal()
            salvus_client.project_last_snapshot_time
                project_id : @project.project_id
                cb         : (err, time) =>
                    if err or not time?
                        time = @_last_snapshot_time
                    if @_last_snapshot_time?
                        d = dialog.find(".project-move-snapshot-last-timeago")
                        d.attr('title',(new Date(1000*@_last_snapshot_time)).toISOString()).timeago()
            dialog.find(".btn-close").click(() -> dialog.modal('hide'); return false)
            dialog.find(".btn-submit").click () =>
                @container.find(".project-location").text("moving...")
                @container.find(".project-location-heading").icon_spin(start:true)
                alert_message(timeout:60, message:"Moving project '#{@project.title}': this takes a few minutes and changes you make during the move will be lost...")
                dialog.modal('hide')
                salvus_client.move_project
                    project_id : @project.project_id
                    cb         : (err, location) =>
                        @container.find(".project-location-heading").icon_spin(false)
                        if err
                            alert_message(timeout:60, type:"error", message:"Error moving project '#{@project.title}' -- #{err}")
                        else
                            alert_message(timeout:60, type:"success", message:"Successfully moved project '#{@project.title}'!")
                            @project.location = location
                            @set_location()

            return false

    init_add_collaborators: () =>
        input   = @container.find(".project-add-collaborator-input")
        select  = @container.find(".project-add-collaborator-select")
        collabs = @container.find(".project-collaborators")
        collabs_loading = @container.find(".project-collaborators-loading")

        add_button = @container.find("a[href=#add-collaborator]").tooltip(delay:{ show: 500, hide: 100 })
        select.change () =>
            if select.find(":selected").length == 0
                add_button.addClass('disabled')
            else
                add_button.removeClass('disabled')


        remove_collaborator = (c) =>
            # c = {first_name:? , last_name:?, account_id:?}
            m = "Are you sure that you want to <b>remove</b> #{c.first_name} #{c.last_name} as a collaborator on '#{@project.title}'?"
            bootbox.confirm m, (result) =>
                if not result
                    return
                salvus_client.project_remove_collaborator
                    project_id : @project.project_id
                    account_id : c.account_id
                    cb         : (err, result) =>
                        if err
                            alert_message(type:"error", message:"Error removing collaborator #{c.first_name} #{c.last_name} -- #{err}")
                        else
                            alert_message(type:"success", message:"Successfully removed #{c.first_name} #{c.last_name} as a collaborator on '#{@project.title}'.")
                            update_collaborators()

        already_collab = {}
        update_collaborators = () =>
            collabs_loading.show()
            salvus_client.project_users
                project_id : @project.project_id
                cb : (err, users) =>
                    collabs_loading.hide()
                    if err
                        # TODO: make nicer; maybe have a retry button...
                        collabs.html("(error loading collaborators)")
                        return
                    collabs.empty()
                    already_collab = {}

                    for mode in ['collaborator', 'viewer', 'owner', 'invited_collaborator', 'invited_viewer']
                        for x in users[mode]
                            already_collab[x.account_id] = true
                            c = template_project_collab.clone()
                            c.find(".project-collab-first-name").text(x.first_name)
                            c.find(".project-collab-last-name").text(x.last_name)
                            c.find(".project-collab-mode").text(mode)
                            if mode == 'owner'
                                c.find(".project-close-button").hide()
                                c.css('background-color', '#51a351')
                                c.tooltip(title:"Project owner (cannot be revoked)", delay: { show: 500, hide: 100 })
                            else
                                c.find(".project-close-button").data('collab', x).click () ->
                                    remove_collaborator($(@).data('collab'))
                                    return false

                                if x.account_id == salvus_client.account_id
                                    extra_tip = " (delete to remove your own access to this project)"
                                    c.css("background-color","#bd362f")
                                else
                                    extra_tip = ""


                                if mode == 'collaborator'
                                    c.tooltip(title:"Collaborator"+extra_tip, delay: { show: 500, hide: 100 })
                                else if mode == 'viewer'
                                    if extra_tip == ""
                                        c.css('background-color', '#f89406')
                                    c.tooltip(title:"Viewer"+extra_tip, delay: { show: 500, hide: 100 })
                            collabs.append(c)

        update_collab_list = () =>
            x = input.val()
            if x == ""
                select.html("").hide()
                @container.find("a[href=#invite-friend]").hide()
                @container.find(".project-add-noncloud-collaborator").hide()
                @container.find(".project-add-collaborator").hide()
                return
            input.icon_spin(start:true)
            salvus_client.user_search
                query : input.val()
                limit : 30
                cb    : (err, result) =>
                    input.icon_spin(false)
                    select.html("")
                    result = (r for r in result when not already_collab[r.account_id]?)   # only include not-already-collabs
                    if result.length > 0
                        select.show()
                        select.attr(size:Math.min(10,result.length))
                        @container.find(".project-add-noncloud-collaborator").hide()
                        @container.find(".project-add-collaborator").show()
                        for r in result
                            name = r.first_name + ' ' + r.last_name
                            select.append($("<option>").attr(value:r.account_id, label:name).text(name))
                        select.show()
                        add_button.addClass('disabled')
                    else
                        select.hide()
                        @container.find(".project-add-collaborator").hide()
                        @container.find(".project-add-noncloud-collaborator").show()

        invite_selected = () =>
            for y in select.find(":selected")
                x = $(y)
                name = x.attr('label')
                salvus_client.project_invite_collaborator
                    project_id : @project.project_id
                    account_id : x.attr("value")
                    cb         : (err, result) =>
                        if err
                            alert_message(type:"error", message:"Error adding collaborator -- #{err}")
                        else
                            alert_message(type:"success", message:"Successfully added #{name} as a collaborator.")
                            update_collaborators()

        add_button.click () =>
            if add_button.hasClass('disabled')
                return false
            invite_selected()
            return false

        timer = undefined
        input.keyup (event) ->
            if timer?
                clearTimeout(timer)
            timer = setTimeout(update_collab_list, 100)
            return false

        return update_collaborators

    init_linked_projects: () =>

        @linked_project_list = []
        element    = @container.find(".project-linked-projects-box")
        input      = element.find(".project-add-linked-project-input")
        select     = element.find(".project-add-linked-project-select")
        add_button = element.find("a[href=#add-linked-project]").tooltip(delay:{ show: 500, hide: 100 })
        linked     = element.find(".project-linked-projects")
        loading    = element.find(".project-linked-projects-loading")

        projects   = require('projects')

        select.change () =>
            if select.find(":selected").length == 0
                add_button.addClass('disabled')
            else
                add_button.removeClass('disabled')

        add_projects = (project_ids, cb) =>
            salvus_client.linked_projects
                project_id : @project.project_id
                add        : project_ids
                cb         : (err) =>
                    cb(err)


        remove_project = (project_id, cb) =>
            salvus_client.linked_projects
                project_id : @project.project_id
                remove     : project_id
                cb         : (err) =>
                    if err
                        alert_message(type:'error', message:'error deleted selected projects')
                        cb?()
                    else
                        update_linked_projects(cb)

        add_selected = (cb) =>
            add_projects ($(y).attr('value') for y in select.find(":selected")), (err) =>
                if err
                    alert_message(type:'error', message:'error adding selected projects')
                    cb?()
                else
                    update_linked_projects(cb)

        add_button.click () =>
            if add_button.hasClass('disabled')
                return false
            add_selected()
            return false

        # update list of currently linked projects
        update_linked_projects = (cb) =>
            loading.show()
            salvus_client.linked_projects
                project_id : @project.project_id
                cb         : (err, x) =>
                    loading.hide()
                    if err
                        cb?(err); return

                    @linked_project_list = x
                    update_linked_projects_search_list()
                    result = projects.matching_projects(@linked_project_list)

                    linked.empty()
                    for project in result.projects
                        c = template_project_linked.clone()
                        c.find(".project-linked-title").text(project.title)
                        if project.description != "No description"
                            c.find(".project-linked-description").text(project.description)
                        project_id = project.project_id
                        c.find(".project-close-button").data('project_id', project_id).click () ->
                            remove_project($(@).data('project_id'))
                            update_linked_projects()
                            return false
                        c.find("a").data('project_id', project_id).click () ->
                            projects.open_project($(@).data('project_id'))
                            return false
                        linked.append(c)
                    cb?()

        # display result of searching for linked projects
        update_linked_projects_search_list = () =>
            x = input.val()

            if x == ""
                select.html("").hide()
                element.find(".project-add-linked-project").hide()
                element.find(".project-add-linked-projects-desc").hide()
                return

            x = projects.matching_projects(x)
            if @linked_project_list?
                result = (project for project in x.projects when @linked_project_list.indexOf(project.project_id) == -1)
            else
                result = x.projects
            element.find(".project-add-linked-projects-desc").text(x.desc)

            if result.length > 0
                select.html("")
                add_button.addClass('disabled')
                select.show()
                select.attr(size:Math.min(10,result.length))
                element.find(".project-add-linked-project").show()
                for r in result
                    x = r.title
                    if $.trim(r.description) not in ['', 'No description']
                        x += '; ' + r.description
                    select.append($("<option>").attr(value:r.project_id, label:x).text(x))
                select.show()
                add_button.addClass('disabled')
            else
                select.hide()


        timer = undefined
        input.keyup (event) ->
            if timer?
                clearTimeout(timer)
            timer = setTimeout(update_linked_projects_search_list, 100)
            return false

        return update_linked_projects

    init_worksheet_server_restart: () =>
        # Restart worksheet server
        link = @container.find("a[href=#restart-worksheet-server]").tooltip(delay:{ show: 500, hide: 100 })
        link.click () =>
            link.find("i").addClass('fa-spin')
            #link.icon_spin(start:true)
            salvus_client.exec
                project_id : @project.project_id
                command    : "sage_server stop; sage_server start"
                timeout    : 30
                cb         : (err, output) =>
                    link.find("i").removeClass('fa-spin')
                    #link.icon_spin(false)
                    if err
                        alert_message
                            type    : "error"
                            message : "Error trying to restart worksheet server.  Try restarting the project server instead."
                    else
                        alert_message
                            type    : "info"
                            message : "Worksheet server restarted.  Restarted worksheets will use a new Sage session."
                            timeout : 4
            return false

    init_project_restart: () =>
        # Restart local project server
        link = @container.find("a[href=#restart-project]").tooltip(delay:{ show: 500, hide: 100 })
        link.click () =>
            async.series([
                (cb) =>
                    m = "Are you sure you want to restart the project server?  Everything you have running in this project (terminal sessions, Sage worksheets, and anything else) will be killed."
                    bootbox.confirm m, (result) =>
                        if result
                            cb()
                        else
                            cb(true)
                (cb) =>
                    link.find("i").addClass('fa-spin')
                    #link.icon_spin(start:true)
                    alert_message
                        type    : "info"
                        message : "Restarting project server..."
                        timeout : 15
                    salvus_client.restart_project_server
                        project_id : @project.project_id
                        cb         : cb
                (cb) =>
                    link.find("i").removeClass('fa-spin')
                    #link.icon_spin(false)
                    alert_message
                        type    : "success"
                        message : "Successfully restarted project server!  Your terminal and worksheet processes have been reset."
                        timeout : 5
            ])
            return false


    # Completely move the project, possibly moving it if it is on a broken host.
    ###
    init_project_move: () =>
        # Close local project
        link = @container.find("a[href=#move-project]").tooltip(delay:{ show: 500, hide: 100 })
        link.click () =>
            async.series([
                (cb) =>
                    m = "Are you sure you want to <b>MOVE</b> the project?  Everything you have running in this project (terminal sessions, Sage worksheets, and anything else) will be killed and the project will be opened on another server using the most recent snapshot.  This could take about a minute."
                    bootbox.confirm m, (result) =>
                        if result
                            cb()
                        else
                            cb(true)
                (cb) =>
                    link.find("i").addClass('fa-spin')
                    alert_message
                        type    : "info"
                        message : "Moving project..."
                        timeout : 15
                    salvus_client.move_project
                        project_id : @project.project_id
                        cb         : cb
                (cb) =>
                    link.find("i").removeClass('fa-spin')
                    #link.icon_spin(false)
                    alert_message
                        type    : "success"
                        message : "Successfully moved project."
                        timeout : 5
            ])
            return false
    ###

    init_snapshot_link: () =>
        @container.find("a[href=#snapshot]").tooltip(delay:{ show: 500, hide: 100 }).click () =>
            @visit_snapshot()
            return false
        update = () =>
            salvus_client.project_last_snapshot_time
                project_id : @project.project_id
                cb         : (err, time) =>
                    if not err and time?
                        @_last_snapshot_time = time
                        # critical to use replaceWith!
                        c = @container.find(".project-snapshot-last-timeago span")
                        d = $("<span>").attr('title',(new Date(1000*time)).toISOString()).timeago()
                        c.replaceWith(d)
        update()
        @_update_last_snapshot_time = setInterval(update, 60000)

    # browse to the snapshot viewer.
    visit_snapshot: () =>
        @current_path = ['.snapshot']
        @update_file_list_tab()

    init_trash_link: () =>
        @container.find("a[href=#trash]").tooltip(delay:{ show: 500, hide: 100 }).click () =>
            @visit_trash()
            return false

        @container.find("a[href=#empty-trash]").tooltip(delay:{ show: 500, hide: 100 }).click () =>
            bootbox.confirm "<h1><i class='fa-trash-o pull-right'></i></h1> <h5>Are you sure you want to permanently erase the items in the Trash?</h5><br> <span class='lighten'>Old versions of files, including the trash, are stored as snapshots.</span>  ", (result) =>
                if result == true
                    salvus_client.exec
                        project_id : @project.project_id
                        command    : "rm"
                        timeout    : 60
                        args       : ['-rf', '.trash']
                        cb         : (err, result) =>
                            if err
                                alert_message(type:"error", message:"Network error while trying to delete the trash -- #{err}")
                            else if result.event == 'error'
                                alert_message(type:"error", message:"Error deleting the trash -- #{result.error}")
                            else
                                alert_message(type:"success", message:"Successfully deleted the contents of your trash.")
                                @visit_trash()
            return false

    trash_file: (opts) =>
        opts = defaults opts,
            path : required
            cb   : undefined
        async.series([
            (cb) =>
                @ensure_directory_exists(path:'.trash', cb:cb)
            (cb) =>
                @move_file(src:opts.path, dest:'.trash', cb:cb, alert:false, mv_args:['--backup=numbered'])
        ], (err) =>
            opts.cb?(err)
            @update_file_list_tab(true)
        )

    # TODO: was used before; not used now, but might need it in case of problems... (?)
    download_file_using_database: (opts) =>
        opts = defaults opts,
            path    : required
            timeout : 45
            prefix  : undefined   # prefix = added to front of filename
            cb      : undefined   # cb(err) when file download from browser starts.
        salvus_client.read_file_from_project
            project_id : @project.project_id
            path       : opts.path
            timeout    : opts.timeout
            cb         : (err, result) =>
                if err
                    alert_message(type:"error", message:"#{err} -- #{misc.to_json(result)}")
                    opts.cb?(err)
                else if result.event == "error"
                    alert_message(type:"error", message:"File download prevented -- (#{result.error})")
                    opts.cb?(result.error)
                else
                    url = result.url + "&download"
                    if opts.prefix?
                        i = url.lastIndexOf('/')
                        url = url.slice(0,i+1) + opts.prefix + url.slice(i+1)
                    iframe = $("<iframe>").addClass('hide').attr('src', url).appendTo($("body"))
                    setTimeout((() -> iframe.remove()), 30000)
                    opts.cb?()

    download_file: (opts) =>
        opts = defaults opts,
            path    : required
            timeout : 45
            cb      : undefined   # cb(err) when file download from browser starts.

        url = "#{window.salvus_base_url}/#{@project.project_id}/raw/#{opts.path}"
        download_file(url)
        bootbox.alert("If <b>#{opts.path}</b> should be downloading.  If not, <a target='_blank' href='#{url}'>click here</a>.")
        opts.cb?()

    open_file_in_another_browser_tab: (path) =>
        salvus_client.read_file_from_project
            project_id : @project.project_id
            path       : path
            cb         : (err, result) =>
                window.open(result.url)


    open_file: (opts) =>
        opts = defaults opts,
            path       : required
            foreground : true      # display in foreground as soon as possible

        ext = filename_extension(opts.path)
        @editor.open opts.path, (err, opened_path) =>
            if err
                alert_message(type:"error", message:"Error opening '#{path}' -- #{err}", timeout:10)
            else
                if opts.foreground
                    @display_tab("project-editor")
                @editor.display_tab(path:opened_path, foreground:opts.foreground)

    switch_displayed_branch: (new_branch) =>
        if new_branch != @meta.display_branch
            @meta.display_branch = new_branch
            @update_file_list_tab()
            @update_commits_tab()

    update_commits_tab: () =>
        {commit_list, commits} = @meta.logs[@meta.display_branch]

        # Set the selector that allows one to choose the current branch.
        select = @container.find(".project-commits-branch")
        select.empty()
        for branch in @meta.branches
            select.append($("<option>").text(branch).attr("value",branch))
        select.val(@meta.display_branch)
        that = @
        select.change  () ->
            that.switch_displayed_branch($(@).val())
            return false

        # Set the list of commits for the current branch.
        list = @container.find(".project-commits-list")
        list.empty()
        for id in commit_list
            entry = commits[id]
            t = template_project_commit_single.clone()
            t.find(".project-commit-single-message").text(trunc(entry.message, 80))
            t.find(".project-commit-single-author").text(entry.author)
            t.find(".project-commit-single-date").attr('title', entry.date).timeago()
            t.find(".project-commit-single-sha").text(id.slice(0,10))
            list.append(t)

    # Display all the branches, along with information about each one.
    update_branches_tab: () =>
        list = @container.find(".project-branches-list")
        list.empty()

        current_branch = @meta.current_branch
        @container.find(".project-branch").text(current_branch)
        that = @

        for branch in @meta.branches
            t = template_project_branch_single.clone()
            t.find(".project-branch-single-name").text(branch)
            if branch == current_branch
                t.addClass("project-branch-single-current")
                t.find("a[href=#checkout]").hide()
                #t.find("a[href=#compare]").hide()
                t.find("a[href=#merge]").hide()
            t.data('branch', branch)

            # TODO -- combine following three into a single loop

            # Make it so clicking on the "Checkout" button checks out a given branch.
            t.find("a[href=#checkout]").data("branch", branch).click (evt) ->
                branch = $(@).data('branch')
                that.branch_op(branch:branch, op:'checkout')
                return false

            t.find("a[href=#delete]").data("branch",branch).click (evt) ->
                branch = $(@).data('branch')
                # TODO -- stern warnings
                that.branch_op(branch:branch, op:'delete')
                return false

            t.find("a[href=#merge]").data("branch",branch).click (evt) ->
                branch = $(@).data('branch')
                # TODO -- stern warnings
                that.branch_op(branch:branch, op:'merge')
                return false

            list.append(t)

        @container.find(".project-branches").find("input").attr('placeholder',"Create a new branch from '#{current_branch}'...")

    #########################################
    # Operations on files in a path and branch.
    #########################################

    path_action: (opts) =>
        opts = defaults opts,
            action  : required     # 'delete', 'move'
            branch  : undefined    # defaults to displayed branch
            path    : undefined    # defaults to displayed current_path
            commit_mesg : required
            extra_options : undefined  # needed for some actions

        spin_timer = undefined

        async.series([
            # Display the file/listing spinner
            (cb) =>
                spinner = @container.find(".project-file-listing-spinner")
                spin_timer = setTimeout((()->spinner.show().spin()), 500)
                cb()
            # Switch to different branch if necessary
            (cb) =>
                if opts.branch != @meta.current_branch
                    @branch_op(branch:opts.branch, op:'checkout', cb:cb)
                else
                    cb()

            # Carry out the action
            (cb) =>
                switch opts.action
                    when 'delete'
                        salvus_client.remove_file_from_project
                            project_id : @project.project_id
                            path       : opts.path
                            cb         : (err, mesg) =>
                                if err
                                    cb(err)
                                else if mesg.event == "error"
                                    cb(mesg.error)
                                else
                                    @current_path.pop()
                                    cb()
                    when 'move'
                        salvus_client.move_file_in_project
                            project_id : @project.project_id
                            src        : opts.path
                            dest       : opts.extra_options.dest
                            cb         : (err, mesg) =>
                                if err
                                    cb(err)
                                else if mesg.event == "error"
                                    cb(mesg.error)
                                else
                                    @current_path = opts.extra_options.dest.split('/')
                                    cb()
                    else
                        cb("unknown path action #{opts.action}")

            # Reload the files/branches/etc to take into account new commit, file deletions, etc.
            (cb) =>
                clearTimeout(spin_timer)
                @update_file_list_tab()
                cb()

        ], (err) ->
            if err
                alert_message(type:"error", message:err)
        )

project_pages = {}

# Function that returns the project page for the project with given id,
# or creates it if it doesn't exist.
project_page = exports.project_page = (project) ->
    p = project_pages[project.project_id]
    if p?
        return p
    p = new ProjectPage(project)
    project_pages[project.project_id] = p
    return p


# Apply various transformations to url's before downloading a file using the "+ New" from web thing:
# This is useful, since people often post a link to a page that *hosts* raw content, but isn't raw
# content, e.g., ipython nbviewer, trac patches, github source files (or repos?), etc.

URL_TRANSFORMS =
    'http://trac.sagemath.org/attachment/ticket/':'http://trac.sagemath.org/raw-attachment/ticket/'
    'http://nbviewer.ipython.org/urls/':'https://'


transform_get_url = (url) ->  # returns something like {command:'wget', args:['http://...']}
    if misc.startswith(url, "https://github.com/") and url.indexOf('/blob/') != -1
        url = url.replace("https://github.com", "https://raw.github.com").replace("/blob/","/")

    if misc.startswith(url, 'git@github.com:')
        command = 'git'  # kind of useless due to host keys...
        args = ['clone', url]
    else if url.slice(url.length-4) == ".git"
        command = 'git'
        args = ['clone', url]
    else
        # fall back
        for a,b of URL_TRANSFORMS
            url = url.replace(a,b)  # only replaces first instance, unlike python.  ok for us.
        command = 'wget'
        args = [url]

    return {command:command, args:args}



