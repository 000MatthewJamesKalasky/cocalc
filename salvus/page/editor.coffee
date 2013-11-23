##################################################
# Editor for files in a project
##################################################

async = require('async')

message = require('message')

{salvus_client} = require('salvus_client')
{EventEmitter}  = require('events')
{alert_message} = require('alerts')

feature = require("feature")
IS_MOBILE = feature.IS_MOBILE

misc = require('misc')
# TODO: undo doing the import below -- just use misc.[stuff] is more readable.
{copy, trunc, from_json, to_json, keys, defaults, required, filename_extension, len, path_split, uuid} = require('misc')

syncdoc = require('syncdoc')

top_navbar =  $(".salvus-top_navbar")

codemirror_associations =
    c      : 'text/x-c'
    'c++'  : 'text/x-c++src'
    cql    : 'text/x-sql'
    cpp    : 'text/x-c++src'
    cc     : 'text/x-c++src'
    conf   : 'nginx'   # should really have a list of different types that end in .conf and autodetect based on heuristics, letting user change.
    csharp : 'text/x-csharp'
    'c#'   : 'text/x-csharp'
    coffee : 'coffeescript'
    css    : 'css'
    diff   : 'text/x-diff'
    dtd    : 'application/xml-dtd'
    e      : 'text/x-eiffel'
    ecl    : 'ecl'
    f      : 'text/x-fortran'    # https://github.com/mgaitan/CodeMirror/tree/be73b866e7381da6336b258f4aa75fb455623338/mode/fortran
    f90    : 'text/x-fortran'
    f95    : 'text/x-fortran'
    h      : 'text/x-c++hdr'
    html   : 'htmlmixed'
    java   : 'text/x-java'
    jl     : 'text/x-julia'
    js     : 'javascript'
    lua    : 'lua'
    m      : 'text/x-octave'
    md     : 'markdown'
    mysql  : 'text/x-sql'
    patch  : 'text/x-diff'

    gp     : 'text/pari'
    pari   : 'text/pari'

    php    : 'php'
    py     : 'python'
    pyx    : 'python'
    pl     : 'text/x-perl'
    r      : 'r'
    rst    : 'rst'
    rb     : 'text/x-ruby'
    sage   : 'python'
    sagews : 'sagews'
    scala  : 'text/x-scala'
    sh     : 'shell'
    spyx   : 'python'
    sql    : 'text/x-sql'
    txt    : 'text'
    tex    : 'stex'
    toml   : 'text/x-toml'
    bib    : 'stex'
    bbl    : 'stex'
    xml    : 'xml'
    yaml   : 'yaml'
    ''     : 'text'

file_associations = exports.file_associations = {}
for ext, mode of codemirror_associations
    file_associations[ext] =
        editor : 'codemirror'
        opts   : {mode:mode}

file_associations['tex'] =
    editor : 'latex'
    icon   : 'fa-edit'
    opts   : {mode:'stex', indent_unit:4, tab_size:4}

file_associations['html'] =
    editor : 'codemirror'
    icon   : 'fa-edit'
    opts   : {mode:'htmlmixed', indent_unit:4, tab_size:4}

file_associations['css'] =
    editor : 'codemirror'
    icon   : 'fa-edit'
    opts   : {mode:'css', indent_unit:4, tab_size:4}

file_associations['sage-terminal'] =
    editor : 'terminal'
    icon   : 'fa-credit-card'
    opts   : {}

file_associations['term'] =
    editor : 'terminal'
    icon   : 'fa-credit-card'
    opts   : {}

file_associations['ipynb'] =
    editor : 'ipynb'
    icon   : 'fa-list-alt'
    opts   : {}

file_associations['sage-worksheet'] =
    editor : 'worksheet'
    icon   : 'fa-list-ul'
    opts   : {}

file_associations['sage-spreadsheet'] =
    editor : 'spreadsheet'
    opts   : {}

file_associations['sage-slideshow'] =
    editor : 'slideshow'
    opts   : {}

for ext in ['png', 'jpg', 'gif', 'svg']
    file_associations[ext] =
        editor : 'image'
        opts   : {}

file_associations['pdf'] =
    editor : 'pdf'
    opts   : {}


# Multiplex'd worksheet mode

diffsync = require('diffsync')
MARKERS  = diffsync.MARKERS

sagews_decorator_modes = [
    ['coffeescript', 'coffeescript'],
    ['cython'      , 'python'],
    ['file'        , 'text'],
    ['html'        , 'htmlmixed'],
    ['javascript'  , 'javascript'],
    ['latex'       , 'stex']
    ['lisp'        , 'ecl'],
    ['md'          , 'markdown'],
    ['gp'          , 'text/pari'],
    ['perl'        , 'text/x-perl'],
    ['python3'     , 'python'],
    ['python'      , 'python'],
    ['ruby'        , 'text/x-ruby'],   # !! more specific name must be first or get mismatch!
    ['r'           , 'r'],
    ['sage'        , 'python'],
    ['script'      , 'shell'],
    ['sh'          , 'shell'],
]

CodeMirror.defineMode "sagews", (config) ->
    options = []
    for x in sagews_decorator_modes
        options.push(open:"%" + x[0], close : MARKERS.cell, mode : CodeMirror.getMode(config, x[1]))
    return CodeMirror.multiplexingMode(CodeMirror.getMode(config, "python"), options...)

# Given a text file (defined by content), try to guess
# what the extension should be.
guess_file_extension_type = (content) ->
    content = $.trim(content)
    i = content.indexOf('\n')
    first_line = content.slice(0,i).toLowerCase()
    if first_line.slice(0,2) == '#!'
        # A script.  What kind?
        if first_line.indexOf('python') != -1
            return 'py'
        if first_line.indexOf('bash') != -1 or first_line.indexOf('sh') != -1
            return 'sh'
    if first_line.indexOf('html') != -1
        return 'html'
    if first_line.indexOf('/*') != -1 or first_line.indexOf('//') != -1   # kind of a stretch
        return 'c++'
    return undefined

SEP = "\uFE10"

_local_storage_prefix = (project_id, filename, key) ->
    s = project_id
    if filename?
        s += filename + SEP
    if key?
        s += key
    return s
#
# Set or get something about a project from local storage:
#
#    local_storage(project_id):  returns everything known about this project.
#    local_storage(project_id, filename):  get everything about given filename in project
#    local_storage(project_id, filename, key):  get value of key for given filename in project
#    local_storage(project_id, filename, key, value):   set value of key
#
# In all cases, returns undefined if localStorage is not supported in this browser.
#

local_storage_delete = exports.local_storage_delete = (project_id, filename, key) ->
    storage = window.localStorage
    if storage?
        prefix = _local_storage_prefix(project_id, filename, key)
        n = prefix.length
        for k, v of storage
            if k.slice(0,n) == prefix
                delete storage[k]

local_storage = exports.local_storage = (project_id, filename, key, value) ->
    storage = window.localStorage
    if storage?
        prefix = _local_storage_prefix(project_id, filename, key)
        n = prefix.length
        if filename?
            if key?
                if value?
                    storage[prefix] = misc.to_json(value)
                else
                    x = storage[prefix]
                    if not x?
                        return x
                    else
                        return misc.from_json(x)
            else
                # Everything about a given filename
                obj = {}
                for k, v of storage
                    if k.slice(0,n) == prefix
                        obj[k.split(SEP)[1]] = v
                return obj
        else
            # Everything about project
            obj = {}
            for k, v of storage
                if k.slice(0,n) == prefix
                    x = k.slice(n)
                    z = x.split(SEP)
                    filename = z[0]
                    key = z[1]
                    if not obj[filename]?
                        obj[filename] = {}
                    obj[filename][key] = v
            return obj

templates = $("#salvus-editor-templates")

class exports.Editor
    constructor: (opts) ->
        opts = defaults opts,
            project_page   : required
            initial_files : undefined # if given, attempt to open these files on creation
            counter       : undefined # if given, is a jQuery set of DOM objs to set to the number of open files

        @counter = opts.counter

        @project_page  = opts.project_page
        @project_path = opts.project_page.project.location.path
        @project_id = opts.project_page.project.project_id
        @element = templates.find(".salvus-editor").clone().show()


        @nav_tabs = @element.find(".nav-pills")

        @tabs = {}   # filename:{useful stuff}

        @init_openfile_search()
        @init_close_all_tabs_button()

        @element.find("a[href=#save-all]").click () =>
            @save()
            return false

        if opts.initial_files?
            for filename in opts.initial_files
                @open(filename)

        # TODO -- maybe neither of these get freed properly when project is closed.
        # Also -- it's a bit weird to call them even if project not currently visible.
        # Add resize trigger
        $(window).resize(@_window_resize_while_editing)

        $(document).on 'keyup', (ev) =>
            if (ev.metaKey or ev.ctrlKey) and ev.keyCode == 79
                @focus()
                @project_page.display_tab("project-editor")
                return false


    focus: () =>
        @hide_editor_content()
        @show_recent_file_list()
        @element.find(".salvus-editor-search-openfiles-input").focus()

    hide_editor_content: () =>
        @_editor_content_visible = false
        @element.find(".salvus-editor-content").hide()

    show_editor_content: () =>
        @_editor_content_visible = true
        @element.find(".salvus-editor-content").show()
        # temporary / ugly
        for tab in @project_page.tabs
            tab.label.removeClass('active')

        @project_page.container.css('position', 'fixed')


    # Used for resizing editor windows.
    editor_top_position: () =>
        if $(".salvus-fullscreen-activate").is(":visible")
            return @element.find(".salvus-editor-content").position().top
        else
            return 0

    refresh: () =>
        @_window_resize_while_editing()

    _window_resize_while_editing: () =>
        @resize_open_file_tabs()
        if not @active_tab? or not @_editor_content_visible
            return
        @active_tab.editor().show()

    # This really closes the "recent files" page.  The name is confusing
    # due to partial refactor of code (i.e., historical reasons).
    init_close_all_tabs_button: () =>
        @element.find("a[href=#close-all-tabs]").click () =>
            undo = @element.find("a[href=#undo-close-all-tabs]")
            if not undo.data('files')?
                undo.data('files', [])
            v = undo.data('files')
            for filename, tab of @tabs
                if tab.link.is(":visible")
                    @remove_from_recent(filename)
                    if filename not in v
                        v.push(filename)
            undo.show().click () =>
                undo.hide()
                for filename in undo.data('files')
                    @tabs[filename]?.link.show()
                return false
            setTimeout((() => undo.hide()), 60000)

            return false

    init_openfile_search: () =>
        search_box = @element.find(".salvus-editor-search-openfiles-input")
        include = 'active' #salvus-editor-openfile-included-in-search'
        exclude = 'salvus-editor-openfile-excluded-from-search'
        search_box.focus () =>
            search_box.select()

        update = (event) =>
            @active_tab?.editor().hide()

            if event?
                if (event.metaKey or event.ctrlKey) and event.keyCode == 79     # control-o
                    @project_page.display_tab("project-new-file")
                    return false

                if event.keyCode == 27  and @active_tab? # escape - open last viewed tab
                    @display_tab(path:@active_tab.filename)
                    return

            v = $.trim(search_box.val()).toLowerCase()
            if v == ""
                for filename, tab of @tabs
                    tab.link.removeClass(include)
                    tab.link.removeClass(exclude)
                match = (s) -> true
            else
                terms = v.split(' ')
                match = (s) ->
                    s = s.toLowerCase()
                    for t in terms
                        if s.indexOf(t) == -1
                            return false
                    return true

            first = true

            for link in @nav_tabs.children()
                tab = $(link).data('tab')
                filename = tab.filename
                if match(filename)
                    if first and event?.keyCode == 13 # enter -- select first match (if any)
                        @display_tab(path:filename)
                        first = false
                    if v != ""
                        tab.link.addClass(include); tab.link.removeClass(exclude)
                else
                    if v != ""
                        tab.link.addClass(exclude); tab.link.removeClass(include)

        @element.find(".salvus-editor-search-openfiles-input-clear").click () =>
            search_box.val('')
            update()
            search_box.select()
            return false

        search_box.keyup(update)

    update_counter: () =>
        if @counter?
            @counter.text(len(@tabs))

    open: (filename, cb) =>   # cb(err, actual_opened_filename)
        if not filename?
            cb?("BUG -- open(undefined) makes no sense")
            return

        if filename == ".sagemathcloud.log"
            cb?("You can only edit '.sagemathcloud.log' via the terminal.")
            return

        if filename_extension(filename).toLowerCase() == "sws"   # sagenb worksheet
            alert_message(type:"info",message:"Opening converted Sagemath Cloud worksheet file instead of '#{filename}...")
            @convert_sagenb_worksheet filename, (err, sagews_filename) =>
                if not err
                    @open(sagews_filename, cb)
                else
                    cb?("Error converting Sage Notebook sws file -- #{err}")
            return

        if filename_extension(filename).toLowerCase() == "docx"   # Microsoft Word Document
            alert_message(type:"info", message:"Opening converted plane text file instead of '#{filename}...")
            @convert_docx_file filename, (err, new_filename) =>
                if not err
                    @open(new_filename, cb)
                else
                    cb?("Error converting Microsoft Docx file -- #{err}")
            return

        if not @tabs[filename]?   # if it is defined, then nothing to do -- file already loaded
            @tabs[filename] = @create_tab(filename:filename)

        cb?(false, filename)

    convert_sagenb_worksheet: (filename, cb) =>
        salvus_client.exec
            project_id : @project_id
            command    : "sws2sagews.py"
            args       : [filename]
            cb         : (err, output) =>
                if err
                    cb("#{err}, #{misc.to_json(output)}")
                else
                    cb(false, filename.slice(0,filename.length-3) + 'sagews')

    convert_docx_file: (filename, cb) =>
        salvus_client.exec
            project_id : @project_id
            command    : "docx2txt.py"
            args       : [filename]
            cb         : (err, output) =>
                if err
                    cb("#{err}, #{misc.to_json(output)}")
                else
                    cb(false, filename.slice(0,filename.length-4) + 'txt')

    file_options: (filename, content) =>   # content may be undefined
        ext = filename_extension(filename)?.toLowerCase()
        if not ext? and content?   # no recognized extension, but have contents
            ext = guess_file_extension_type(content)
        x = file_associations[ext]
        if not x?
            x = file_associations['']
        return x

    # This is just one of thetabs in the recent files list, not at the very top
    create_tab: (opts) =>
        opts = defaults opts,
            filename     : required
            content      : undefined

        filename = opts.filename
        if @tabs[filename]?
            return @tabs[filename]

        content = opts.content
        opts0 = @file_options(filename, content)
        extra_opts = copy(opts0.opts)
        if opts.session_uuid?
            extra_opts.session_uuid = opts.session_uuid

        local_storage(@project_id, filename, "auto_open", true)

        link = templates.find(".salvus-editor-filename-pill").clone().show()
        link_filename = link.find(".salvus-editor-tab-filename")
        link_filename.text(trunc(filename,64))

        link.find(".salvus-editor-close-button-x").click () =>
            if ignore_clicks
                return false
            @remove_from_recent(filename)

        containing_path = misc.path_split(filename).head
        ignore_clicks = false
        link.find("a").mousedown (e) =>
            if ignore_clicks
                return false
            foreground = not(e.which==2 or e.ctrlKey)
            @display_tab(path:link_filename.text(), foreground:foreground)
            if foreground
                @project_page.set_current_path(containing_path)
            return false

        create_editor_opts =
            editor_name : opts0.editor
            filename    : filename
            content     : content
            extra_opts  : extra_opts

        editor = undefined
        @tabs[filename] =
            link     : link
            filename : filename

            editor   : () =>
                if editor?
                    return editor
                else
                    editor = @create_editor(create_editor_opts)
                    @element.find(".salvus-editor-content").append(editor.element.hide())
                    @create_opened_file_tab(filename)
                    return editor

            hide_editor : () -> editor?.hide()

            editor_open : () -> editor?   # editor is defined if the editor is open.

            close_editor: () ->
                if editor?
                    editor.disconnect_from_session()
                    editor.remove()

                editor = undefined
                # We do *NOT* want to recreate the editor next time it is opened with the *same* options, or we
                # will end up overwriting it with stale contents.
                delete create_editor_opts.content


        link.data('tab', @tabs[filename])
        ###
        link.draggable
            zIndex      : 1000
            #containment : @element
            stop        : () =>
                ignore_clicks = true
                setTimeout( (() -> ignore_clicks=false), 100)
        ###

        @nav_tabs.append(link)

        @update_counter()
        return @tabs[filename]

    create_editor: (opts) =>
        {editor_name, filename, content, extra_opts} = defaults opts,
            editor_name : required
            filename    : required
            content     : undefined
            extra_opts  : required

        #console.log("create_editor", opts)

        if editor_name == 'codemirror'
            if filename.slice(filename.length-7) == '.sagews'
                typ = 'worksheet'  # TODO: only because we don't use Worksheet below anymore
            else
                typ = 'file'
        else
            typ = editor_name
        @project_page.project_activity({event:'open', filename:filename, type:typ})


        # Some of the editors below might get the content later and will call @file_options again then.
        switch editor_name
            # codemirror is the default... TODO: JSON, since I have that jsoneditor plugin.
            when 'codemirror', undefined
                editor = codemirror_session_editor(@, filename, extra_opts)
            when 'terminal'
                editor = new Terminal(@, filename, content, extra_opts)
            when 'worksheet'
                editor = new Worksheet(@, filename, content, extra_opts)
            when 'spreadsheet'
                editor = new Spreadsheet(@, filename, content, extra_opts)
            when 'slideshow'
                editor = new Slideshow(@, filename, content, extra_opts)
            when 'image'
                editor = new Image(@, filename, content, extra_opts)
            when 'latex'
                editor = new LatexEditor(@, filename, content, extra_opts)
            when 'pdf'
                editor = new PDF_PreviewEmbed(@, filename, content, extra_opts)
            when 'ipynb'
                editor = new IPythonNotebook(@, filename, content, extra_opts)
            else
                throw("Unknown editor type '#{editor_name}'")

        return editor

    create_opened_file_tab: (filename) =>
        link_bar = @project_page.container.find(".project-pages")

        link = templates.find(".salvus-editor-filename-pill").clone()
        link.tooltip(title:filename, placement:'bottom', delay:{show: 500, hide: 0})

        link.data('name', filename)

        link_filename = link.find(".salvus-editor-tab-filename")
        display_name = path_split(filename).tail
        link_filename.text(display_name)

        open_file = (name) =>
            @project_page.set_current_path(misc.path_split(name).head)
            @project_page.display_tab("project-editor")
            @display_tab(path:name)

        close_tab = () =>
            if ignore_clicks
                return false

            if @active_tab? and @active_tab.filename == filename
                @active_tab = undefined

            if not @active_tab?
                next = link.next()
                # skip past div's inserted by tooltips
                while next.is("div")
                    next = next.next()
                name = next.data('name')  # need li selector because tooltip inserts itself after in DOM
                if name?
                    open_file(name)

            link.tooltip('destroy')
            link.hide()
            link.remove()

            if not @active_tab?
                # open last file if there is one
                next_link = link_bar.find("li").last()
                name = next_link.data('name')
                if name?
                    open_file(name)
                else
                    # just show the recent files
                    @project_page.display_tab('project-editor')

            tab = @tabs[filename]
            if tab?
                if tab.open_file_pill?
                    delete tab.open_file_pill
                tab.editor()?.disconnect_from_session()
                tab.close_editor()

            @resize_open_file_tabs()
            return false

        link.find(".salvus-editor-close-button-x").click(close_tab)

        ignore_clicks = false
        link.find("a").mousedown (e) =>
            if ignore_clicks
                return false
            if e.which==2 or e.ctrlKey
                # middle (or control-) click on open tab: close the editor
                close_tab()
                return false
            open_file(filename)
            return false

        #link.draggable
        #    zIndex      : 1000
        #    containment : "parent"
        #    stop        : () =>
        #        ignore_clicks = true
        #        setTimeout( (() -> ignore_clicks=false), 100)

        @tabs[filename].open_file_pill = link
        @tabs[filename].close_tab = close_tab

        link_bar.append(link)
        @resize_open_file_tabs()

    open_file_tabs: () =>
        x = []
        file_tabs = false
        for a in @project_page.container.find(".project-pages").children()
            t = $(a)
            if t.hasClass("project-search-menu-item")
                file_tabs = true
                continue
            else if file_tabs and t.hasClass("salvus-editor-filename-pill")
                x.push(t)
        return x

    close_all_open_files: () =>
        for filename, tab of @tabs
            tab.close_editor()

    resize_open_file_tabs: () =>
        # Make a list of the tabs after the search menu.
        x = @open_file_tabs()
        if x.length == 0
            return

        # Determine the width
        if $(window).width() <= 979
            # responsive mode
            width = 204
        else
            start = x[0].offset().left
            end   = x[0].parent().offset().left + x[0].parent().width()

            n = x.length
            if n <= 2
                n = 3
            width = (end - start - 10)/n
            if width < 0
                width = 0

        for a in x
            a.width(width)

    make_open_file_pill_active: (link) =>
        @project_page.container.find(".project-pages").children().removeClass('active')
        link.addClass('active')

    # Close tab with given filename
    close: (filename) =>
        tab = @tabs[filename]
        if not tab? # nothing to do -- tab isn't opened anymore
            return

        # Disconnect from remote session (if relevant)
        if tab.editor_open()
            tab.editor().disconnect_from_session()
            tab.editor().remove()

        tab.link.remove()
        tab.close_tab?()
        delete @tabs[filename]
        @update_counter()

    remove_from_recent: (filename) =>
        # Do not show this file in "recent" next time.
        local_storage_delete(@project_id, filename, "auto_open")
        # Hide from the DOM.
        # This same tab object also stores the top tab and editor, so we don't just delete it.
        @tabs[filename]?.link.hide()

    # Reload content of this tab.  Warn user if this will result in changes.
    reload: (filename) =>
        tab = @tabs[filename]
        if not tab? # nothing to do
            return
        salvus_client.read_text_file_from_project
            project_id : @project_id
            timeout    : 5
            path       : filename
            cb         : (err, mesg) =>
                if err
                    alert_message(type:"error", message:"Communications issue loading new version of #{filename} -- #{err}")
                else if mesg.event == 'error'
                    alert_message(type:"error", message:"Error loading new version of #{filename} -- #{to_json(mesg.error)}")
                else
                    current_content = tab.editor().val()
                    new_content = mesg.content
                    if current_content != new_content
                        @warn_user filename, (proceed) =>
                            if proceed
                                tab.editor().val(new_content)

    # Warn user about unsaved changes (modal)
    warn_user: (filename, cb) =>
        cb(true)

    hide_recent_file_list: () =>
        $(".salvus-editor-recent-files").hide()
        $(".project-editor-recent-files-header").hide()

    show_recent_file_list: () =>
        $(".salvus-editor-recent-files").show()
        $(".project-editor-recent-files-header").show()

    # Make the tab appear in the tabs at the top, and if foreground=true, also make that tab active.
    display_tab: (opts) =>
        opts = defaults opts,
            path       : required
            foreground : true      # display in foreground as soon as possible
        filename = opts.path

        if not @tabs[filename]?
            return

        if opts.foreground
            @push_state('files/' + opts.path)
            @hide_recent_file_list()
            @show_editor_content()

        prev_active_tab = @active_tab
        for name, tab of @tabs
            if name == filename
                @active_tab = tab
                ed = tab.editor()

                if opts.foreground
                    ed.show()
                    setTimeout((() -> ed.show(); ed.focus()), 100)
                    @element.find(".btn-group").children().removeClass('disabled')

                top_link = @active_tab.open_file_pill
                if top_link?
                    if opts.foreground
                        @make_open_file_pill_active(top_link)
                else
                    @create_opened_file_tab(filename)
                    if opts.foreground
                        @make_open_file_pill_active(@active_tab.open_file_pill)
            else
                tab.hide_editor()

        if prev_active_tab? and prev_active_tab.filename != @active_tab.filename and @tabs[prev_active_tab.filename]?   # ensure is still open!
            @nav_tabs.prepend(prev_active_tab.link)

    add_tab_to_navbar: (filename) =>
        navbar = require('top_navbar').top_navbar
        tab = @tabs[filename]
        if not tab?
            return
        id = @project_id + filename
        if not navbar.pages[id]?
            navbar.add_page
                id     : id
                label  : misc.path_split(filename).tail
                onshow : () =>
                    navbar.switch_to_page(@project_id)
                    @display_tab(path:filename)
                    navbar.make_button_active(id)

    onshow: () =>  # should be called when the editor is shown.
        #if @active_tab?
        #    @display_tab(@active_tab.filename)
        if not IS_MOBILE
            @element.find(".salvus-editor-search-openfiles-input").focus()
        @push_state('recent')

    push_state: (url) =>
        if not url?
            url = @_last_history_state
        if not url?
            url = 'recent'
        @_last_history_state = url
        @project_page.push_state(url)

    # Save the file to disk/repo
    save: (filename, cb) =>       # cb(err)
        if not filename?  # if filename not given, save all *open* files
            tasks = []
            for filename, tab of @tabs
                if tab.editor_open()
                    f = (c) =>
                        @save(arguments.callee.filename, c)
                    f.filename = filename
                    tasks.push(f)
            async.parallel(tasks, cb)
            return

        tab = @tabs[filename]
        if not tab?
            cb?()
            return

        if not tab.editor().has_unsaved_changes()
            # nothing to save
            cb?()
            return

        tab.editor().save(cb)

    change_tab_filename: (old_filename, new_filename) =>
        tab = @tabs[old_filename]
        if not tab?
            # TODO -- fail silently or this?
            alert_message(type:"error", message:"change_tab_filename (bug): attempt to change #{old_filename} to #{new_filename}, but there is no tab #{old_filename}")
            return
        tab.filename = new_filename
        tab.link.find(".salvus-editor-tab-filename").text(new_filename)
        delete @tabs[old_filename]
        @tabs[new_filename] = tab


###############################################
# Abstract base class for editors
###############################################
# Derived classes must:
#    (1) implement the _get and _set methods
#    (2) show/hide/remove
#
# Events ensure that *all* users editor the same file see the same
# thing (synchronized).
#

class FileEditor extends EventEmitter
    constructor: (@editor, @filename, content, opts) ->
        @val(content)

    init_autosave: () =>
        if @_autosave_interval?
            # This function can safely be called again to *adjust* the
            # autosave interval, in case user changes the settings.
            clearInterval(@_autosave_interval)

        # Use the most recent autosave value.
        autosave = require('account').account_settings.settings.autosave
        if autosave
            save_if_changed = () =>
                if not @editor.tabs[@filename]?.editor_open()
                    # don't autosave anymore if the doc is closed -- since autosave references
                    # the editor, which would re-create it, causing the tab to reappear.  Not pretty.
                    clearInterval(@_autosave_interval)
                    return
                if @has_unsaved_changes()
                    if @click_save_button?
                        # nice gui feedback
                        @click_save_button()
                    else
                        @save()
            @_autosave_interval = setInterval(save_if_changed, autosave * 1000)

    val: (content) =>
        if not content?
            # If content not defined, returns current value.
            return @_get()
        else
            # If content is defined, sets value.
            @_set(content)

    # has_unsaved_changes() returns the state, where true means that
    # there are unsaved changed.  To set the state, do
    # has_unsaved_changes(true or false).
    has_unsaved_changes: (val) =>
        if not val?
            return @_has_unsaved_changes
        else
            @_has_unsaved_changes = val

    focus: () => # TODO in derived class

    _get: () =>
        throw("TODO: implement _get in derived class")

    _set: (content) =>
        throw("TODO: implement _set in derived class")

    restore_cursor_position: () =>
        # implement in a derived class if you need this

    disconnect_from_session: (cb) =>
        # implement in a derived class if you need this

    local_storage: (key, value) =>
        return local_storage(@editor.project_id, @filename, key, value)

    show: () =>
        @element.show()

    hide: () =>
        @element.hide()

    remove: () =>
        @element.remove()

    terminate_session: () =>
        # If some backend session on a remote machine is serving this session, terminate it.

    save: (cb) =>
        content = @val()
        if not content?
            # do not overwrite file in case editor isn't initialized
            alert_message(type:"error", message:"Editor of '#{filename}' not initialized, so nothing to save.")
            cb?()
            return

        salvus_client.write_text_file_to_project
            project_id : @editor.project_id
            timeout    : 10
            path       : @filename
            content    : content
            cb         : (err, mesg) =>
                # TODO -- on error, we *might* consider saving to localStorage...
                if err
                    alert_message(type:"error", message:"Communications issue saving #{filename} -- #{err}")
                    cb?(err)
                else if mesg.event == 'error'
                    alert_message(type:"error", message:"Error saving #{filename} -- #{to_json(mesg.error)}")
                    cb?(mesg.error)
                else
                    cb?()

###############################################
# Codemirror-based File Editor
###############################################
class CodeMirrorEditor extends FileEditor
    constructor: (@editor, @filename, content, opts) ->

        editor_settings = require('account').account_settings.settings.editor_settings

        opts = @opts = defaults opts,
            mode              : required
            geometry          : undefined  # (default=full screen);
            read_only         : false
            delete_trailing_whitespace : editor_settings.strip_trailing_whitespace  # delete on save
            allow_javascript_eval : true  # if false, the one use of eval isn't allowed.
            line_numbers      : editor_settings.line_numbers
            first_line_number : editor_settings.first_line_number
            indent_unit       : editor_settings.indent_unit
            tab_size          : editor_settings.tab_size
            smart_indent      : editor_settings.smart_indent
            electric_chars    : editor_settings.electric_chars
            undo_depth        : editor_settings.undo_depth
            match_brackets    : editor_settings.match_brackets
            line_wrapping     : editor_settings.line_wrapping
            style_active_line : 15    # editor_settings.style_active_line  # (a number between 0 and 127)
            bindings          : editor_settings.bindings  # 'standard', 'vim', or 'emacs'
            theme             : editor_settings.theme

            # I'm making the times below very small for now.  If we have to adjust these to reduce load, due to lack
            # of capacity, then we will.  Or, due to lack of optimization (e.g., for big documents). These parameters
            # below would break editing a huge file right now, due to slowness of applying a patch to a codemirror editor.

            cursor_interval   : 1000   # minimum time (in ms) between sending cursor position info to hub -- used in sync version
            sync_interval     : 750    # minimum time (in ms) between synchronizing text with hub. -- used in sync version below

            completions_size  : 20    # for tab completions (when applicable, e.g., for sage sessions)

        @project_id = @editor.project_id
        @element = templates.find(".salvus-editor-codemirror").clone()
        @element.data('editor', @)

        @init_save_button()
        @init_edit_buttons()

        @init_close_button()
        filename = @filename
        if filename.length > 30
            filename = "…" + filename.slice(filename.length-30)
        @element.find(".salvus-editor-codemirror-filename").text(filename)

        elt = @element.find(".salvus-editor-codemirror-input-box").find("textarea")
        elt.text(content)

        extraKeys =
            "Alt-Enter"    : (editor)   => @action_key(execute: true, advance:false, split:false)
            "Cmd-Enter"    : (editor)   => @action_key(execute: true, advance:false, split:false)
            "Ctrl-Enter"   : (editor)   => @action_key(execute: true, advance:true, split:true)
            "Ctrl-;"       : (editor)   => @action_key(split:true, execute:false, advance:false)
            "Cmd-;"        : (editor)   => @action_key(split:true, execute:false, advance:false)
            "Ctrl-\\"      : (editor)   => @action_key(execute:false, toggle_input:true)
            #"Cmd-x"  : (editor)   => @action_key(execute:false, toggle_input:true)
            "Shift-Ctrl-\\" : (editor)   => @action_key(execute:false, toggle_output:true)
            #"Shift-Cmd-y"  : (editor)   => @action_key(execute:false, toggle_output:true)

            "Ctrl-S"       : (editor)   => @click_save_button()
            "Cmd-S"        : (editor)   => @click_save_button()

            "Ctrl-L"       : (editor)   => @goto_line(editor)
            "Cmd-L"        : (editor)   => @goto_line(editor)

            "Ctrl-I"       : (editor)   => @toggle_split_view(editor)
            "Cmd-I"        : (editor)   => @toggle_split_view(editor)

            "Shift-Ctrl-." : (editor)   => @change_font_size(editor, +1)
            "Shift-Ctrl-," : (editor)   => @change_font_size(editor, -1)
            "Shift-Cmd-."  : (editor)   => @change_font_size(editor, +1)
            "Shift-Cmd-,"  : (editor)   => @change_font_size(editor, -1)

            "Shift-Tab"    : (editor)   => editor.unindent_selection()

            "Ctrl-Space"   : "indentAuto"
            "Ctrl-'"       : "indentAuto"

            "Tab"          : (editor)   => @press_tab_key(editor)
            "Shift-Ctrl-C" : (editor)   => @interrupt_key()

        # We will replace this by a general framework...
        if misc.filename_extension(filename) == "sagews"
            evaluate_key = require('account').account_settings.settings.evaluate_key.toLowerCase()
            if evaluate_key == "enter"
                evaluate_key = "Enter"
            else
                evaluate_key = "Shift-Enter"
            extraKeys[evaluate_key] = (editor)   => @action_key(execute: true, advance:true, split:false)

        make_editor = (node) =>
            options =
                firstLineNumber : opts.first_line_number
                autofocus       : false
                mode            : opts.mode
                lineNumbers     : opts.line_numbers
                indentUnit      : opts.indent_unit
                tabSize         : opts.tab_size
                smartIndent     : opts.smart_indent
                electricChars   : opts.electric_chars
                undoDepth       : opts.undo_depth
                matchBrackets   : opts.match_brackets
                lineWrapping    : opts.line_wrapping
                readOnly        : opts.read_only
                styleActiveLine : opts.style_active_line
                extraKeys       : extraKeys
                cursorScrollMargin : 40

            if opts.bindings? and opts.bindings != "standard"
                options.keyMap = opts.bindings
                #cursorBlinkRate: 1000

            if opts.theme? and opts.theme != "standard"
                options.theme = opts.theme

            cm = CodeMirror.fromTextArea(node, options)
            cm.save = () => @click_save_button()

            # The Codemirror themes impose their own weird fonts, but most users want whatever
            # they've configured as "monospace" in their browser.  So we force that back:
            e = $(cm.getWrapperElement())
            e.attr('style', e.attr('style') + '; font-family:monospace !important')  # see http://stackoverflow.com/questions/2655925/apply-important-css-style-using-jquery

            return cm


        @codemirror = make_editor(elt[0])

        elt1 = @element.find(".salvus-editor-codemirror-input-box-1").find("textarea")

        @codemirror1 = make_editor(elt1[0])

        buf = @codemirror.linkedDoc({sharedHist: true})
        @codemirror1.swapDoc(buf)
        $(@codemirror1.getWrapperElement()).css('border-top':'2px solid #aaa')

        @codemirror.on 'focus', () =>
            @codemirror_with_last_focus = @codemirror

        @codemirror1.on 'focus', () =>
            @codemirror_with_last_focus = @codemirror1


        @_split_view = false

        @init_change_event()

    set_theme: (theme) =>
        # Change the editor theme after the editor has been created
        @codemirror.setOption('theme', theme)
        @codemirror1.setOption('theme', theme)
        @opts.theme = theme

    set_cursor_center_focus: (pos, tries=5) =>
        if tries <= 0
            return
        cm = @codemirror_with_last_focus
        if not cm?
            cm = @codemirror
        if not cm?
            return
        cm.setCursor(pos)
        info = cm.getScrollInfo()
        try
            # This call can fail during editor initialization (as of codemirror 3.19, but not before).
            cm.scrollIntoView(pos, info.clientHeight/2)
        catch e
            setTimeout((() => @set_cursor_center_focus(pos, tries-1)), 250)
        cm.focus()

    disconnect_from_session: (cb) =>
        # implement in a derived class if you need this
        @syncdoc?.disconnect_from_session()
        cb?()

    action_key: (opts) =>
        # opts ignored by default; worksheets use them....
        @click_save_button()

    interrupt_key: () =>
        # does nothing for generic editor, but important, e.g., for the sage worksheet editor.

    press_tab_key: (editor) =>
        if editor.somethingSelected()
            CodeMirror.commands.defaultTab(editor)
        else
            @tab_nothing_selected(editor)

    tab_nothing_selected: (editor) =>
        editor.tab_as_space()

    init_edit_buttons: () =>
        that = @
        for name in ['search', 'next', 'prev', 'replace', 'undo', 'redo', 'autoindent',
                     'shift-left', 'shift-right', 'split-view','increase-font', 'decrease-font', 'goto-line' ]
            e = @element.find("a[href=##{name}]")
            e.data('name', name).tooltip(delay:{ show: 500, hide: 100 }).click (event) ->
                that.click_edit_button($(@).data('name'))
                return false

    click_edit_button: (name) =>
        cm = @codemirror_with_last_focus
        if not cm?
            cm = @codemirror
        if not cm?
            return
        switch name
            when 'search'
                CodeMirror.commands.find(cm)
            when 'next'
                if cm._searchState?.query
                    CodeMirror.commands.findNext(cm)
                else
                    CodeMirror.commands.goPageDown(cm)
            when 'prev'
                if cm._searchState?.query
                    CodeMirror.commands.findPrev(cm)
                else
                    CodeMirror.commands.goPageUp(cm)
            when 'replace'
                CodeMirror.commands.replace(cm)
            when 'undo'
                cm.undo()
            when 'redo'
                cm.redo()
            when 'split-view'
                @toggle_split_view(cm)
            when 'autoindent'
                CodeMirror.commands.indentAuto(cm)
            when 'shift-left'
                cm.unindent_selection()
            when 'shift-right'
                @press_tab_key(cm)
            when 'increase-font'
                @change_font_size(cm, +1)
            when 'decrease-font'
                @change_font_size(cm, -1)
            when 'goto-line'
                @goto_line(cm)

    change_font_size: (cm, delta) =>
        elt = $(cm.getWrapperElement())
        size = elt.data('font-size')
        if not size?
            s = elt.css('font-size')
            size = parseInt(s.slice(0,s.length-2))
        new_size = size + delta
        if new_size > 1
            elt.css('font-size', new_size + 'px')
            elt.data('font-size', new_size)
        @show()

    toggle_split_view: (cm) =>
        @_split_view = not @_split_view
        @show()
        @focus()
        cm.focus()

    goto_line: (cm) =>
        focus = () =>
            @focus()
            cm.focus()
        bootbox.prompt "Goto line... (1-#{cm.lineCount()} or n%)", (result) =>
            if result != null
                result = result.trim()
                if result.length >= 1 and result[result.length-1] == '%'
                    line = Math.floor( cm.lineCount() * parseInt(result.slice(0,result.length-1)) / 100.0)
                else
                    line = parseInt(result)-1
                pos = {line:line, ch:0}
                cm.setCursor(pos)
                info = cm.getScrollInfo()
                cm.scrollIntoView(pos, info.clientHeight/2)
            setTimeout(focus, 100)

    init_close_button: () =>
        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

    init_save_button: () =>
        @save_button = @element.find("a[href=#save]").tooltip().click(@click_save_button)
        @save_button.find(".spinner").hide()

    click_save_button: () =>
        if @_saving
            return
        @_saving = true
        #if not @save_button.hasClass('disabled')
        changed = false
        f = () -> changed = true
        @codemirror.on 'change', f
        @save_button.icon_spin(start:true, delay:1000)
        @editor.save @filename, (err) =>
            @codemirror.off(f)
            @save_button.icon_spin(false)
            @_saving = false
            if not err and not changed
                @save_button.addClass('disabled')
                @has_unsaved_changes(false)
        return false

    init_change_event: () =>
        @codemirror.on 'change', (instance, changeObj) =>
            @has_unsaved_changes(true)
            @save_button.removeClass('disabled')

    _get: () =>
        return @codemirror.getValue()

    _set: (content) =>
        {from} = @codemirror.getViewport()
        @codemirror.setValue(content)
        @codemirror.scrollIntoView(from)
        # even better, if available
        @restore_cursor_position()

    restore_cursor_position: () =>
        pos = @local_storage("cursor")
        if pos?
            @set_cursor_center_focus(pos)

    _style_active_line: (rgb) =>
        v = (parseInt(x) for x in rgb.slice(4,rgb.length-1).split(','))
        amount = @opts.style_active_line
        for i in [0..2]
            if v[i] >= 128
                v[i] -= amount
            else
                v[i] += amount
        $("body").append("<style type=text/css>.CodeMirror-activeline{background:rgb(#{v[0]},#{v[1]},#{v[2]});}</style>")

    show: () =>
        if not (@element? and @codemirror?)
            return

        if @syncdoc?
            @syncdoc.sync()

        @element.show()
        @codemirror.refresh()

        if @opts.style_active_line
            @_style_active_line($(@codemirror.getWrapperElement()).css('background-color'))

        if @_split_view
            @codemirror1.refresh()
            $(@codemirror1.getWrapperElement()).show()
        else
            $(@codemirror1.getWrapperElement()).hide()

        height = $(window).height()

        top = @editor.editor_top_position()
        elem_height = height - top - 5

        button_bar_height = @element.find(".salvus-editor-codemirror-button-container").height()
        font_height = @codemirror.defaultTextHeight()

        cm_height = Math.floor((elem_height - button_bar_height)/font_height) * font_height

        @element.css(top:top)
        @element.find(".salvus-editor-codemirror-chat-column").css(top:top+button_bar_height)

        @element.height(elem_height).show()
        @element.show()

        chat = @_chat_is_hidden? and not @_chat_is_hidden
        if chat
            width = @element.find(".salvus-editor-codemirror-chat-column").offset().left
        else
            width = $(window).width()

        if @opts.geometry? and @opts.geometry == 'left half'
            @empty_space = {start: width/2, end:width, top:top+button_bar_height}
            width = width/2

        if @_split_view
            v = [@codemirror, @codemirror1]
            ht = cm_height/2
        else
            v = [@codemirror]
            ht = cm_height

        for cm in v
            scroller = $(cm.getScrollerElement())
            scroller.css('height':ht)
            cm_wrapper = $(cm.getWrapperElement())
            cm_wrapper.css
                height : ht
                width  : width
            cm.refresh()

        if chat
            chat_elt = @element.find(".salvus-editor-codemirror-chat")
            chat_elt.height(cm_height)

            chat_output = chat_elt.find(".salvus-editor-codemirror-chat-output")

            chat_input = chat_elt.find(".salvus-editor-codemirror-chat-input")
            chat_input_top = $(window).height()-chat_input.height() - 15
            chat_input.offset({top:chat_input_top})
            chat_output.height(chat_input_top - top - 41)

        @emit 'show', ht

    focus: () =>
        if not @codemirror?
            return
        @show()
        if not IS_MOBILE
            @codemirror.focus()
            if @_split_view
                @codemirror1.focus()

codemirror_session_editor = exports.codemirror_session_editor = (editor, filename, extra_opts) ->
    #console.log("codemirror_session_editor '#{filename}'")
    ext = filename_extension(filename)

    E = new CodeMirrorEditor(editor, filename, "", extra_opts)
    # Enhance the editor with synchronized session capabilities.
    opts =
        cursor_interval : E.opts.cursor_interval
        sync_interval   : E.opts.sync_interval

    switch ext
        when "sagews"
            # temporary.
            opts =
                cursor_interval : 2000
                sync_interval   : 250
            E.syncdoc = new (syncdoc.SynchronizedWorksheet)(E, opts)
            E.action_key = E.syncdoc.action
            E.interrupt_key = E.syncdoc.interrupt
            E.tab_nothing_selected = () => E.syncdoc.introspect()
        else
            E.syncdoc = new (syncdoc.SynchronizedDocument)(E, opts)
    return E


###############################################
# LateX Editor
###############################################

# Make a (server-side) self-destructing temporary uuid-named directory in path.
tmp_dir = (opts) ->
    opts = defaults opts,
        project_id : required
        path       : '/tmp/'
        ttl        : 120            # self destruct in this many seconds
        cb         : required       # cb(err, directory_name)
    name = "." + uuid()   # hidden
    if "'" in opts.path
        opts.cb("there is a disturbing ' in the path: '#{opts.path}'")
        return
    remove_tmp_dir
        project_id : opts.project_id
        path       : opts.path
        tmp_dir    : name
        ttl        : opts.ttl
    salvus_client.exec
        project_id : opts.project_id
        path       : opts.path
        command    : "mkdir"
        args       : [name]
        cb         : (err, output) =>
            if err
                opts.cb("Problem creating temporary directory in '#{path}'")
            else
                opts.cb(false, name)

remove_tmp_dir = (opts) ->
    opts = defaults opts,
        project_id : required
        path       : required
        tmp_dir    : required
        ttl        : 120            # run in this many seconds (even if client disconnects)
        cb         : undefined
    salvus_client.exec
        project_id : opts.project_id
        command    : "sleep #{opts.ttl} && rm -rf '#{opts.path}/#{opts.tmp_dir}'"
        timeout    : 10 + opts.ttl
        cb         : (err, output) =>
            cb?(err)


# Class that wraps "a remote latex doc with PDF preview":
class PDFLatexDocument
    constructor: (opts) ->
        opts = defaults opts,
            project_id : required
            filename   : required
            image_type : 'png'  # 'png' or 'jpg'

        @project_id = opts.project_id
        @filename   = opts.filename
        @image_type = opts.image_type

        @_pages     = {}
        @num_pages  = 0
        @latex_log  = ''
        s = path_split(@filename)
        @path = s.head
        if @path == ''
            @path = './'
        @filename_tex  = s.tail
        @base_filename = @filename_tex.slice(0, @filename_tex.length-4)
        @filename_pdf  =  @base_filename + '.pdf'

    page: (n) =>
        if not @_pages[n]?
            @_pages[n] = {}
        return @_pages[n]

    _exec: (opts) =>
        opts = defaults opts,
            path        : @path
            project_id  : @project_id
            command     : required
            args        : []
            timeout     : 30
            err_on_exit : false
            bash        : false
            cb          : required
        #console.log(opts.path)
        #console.log(opts.command + ' ' + opts.args.join(' '))
        salvus_client.exec(opts)

    inverse_search: (opts) =>
        opts = defaults opts,
            n          : required   # page number
            x          : required   # x coordinate in unscaled png image coords (as reported by click EventEmitter)...
            y          : required   # y coordinate in unscaled png image coords
            resolution : required   # resolution used in ghostscript
            cb         : required   # cb(err, {input:'file.tex', line:?})

        scale = opts.resolution / 72
        x = opts.x / scale
        y = opts.y / scale
        @_exec
            command : 'synctex'
            args    : ['edit', '-o', "#{opts.n}:#{x}:#{y}:#{@filename_pdf}"]
            path    : @path
            timeout : 7
            cb      : (err, output) =>
                if err
                    opts.cb(err); return
                if output.stderr
                    opts.cb(output.stderr); return
                s = output.stdout
                i = s.indexOf('\nInput:')
                input = s.slice(i+7, s.indexOf('\n',i+3))

                # normalize path to be relative to project home
                j = input.indexOf('/./')
                if j != -1
                    fname = input.slice(j+3)
                else
                    j = input.indexOf('/../')
                    if j != -1
                        fname = input.slice(j+1)
                    else
                        fname = input
                if @path != './'
                    input = @path + '/' + fname
                else
                    input = fname

                i = s.indexOf('Line')
                line = parseInt(s.slice(i+5, s.indexOf('\n',i+1)))
                opts.cb(false, {input:input, line:line-1})   # make line 0-based

    forward_search: (opts) =>
        opts = defaults opts,
            n  : required
            cb : required   # cb(err, {page:?, x:?, y:?})    x,y are in terms of 72dpi pdf units

        @_exec
            command : 'synctex'
            args    : ['view', '-i', "#{opts.n}:0:#{@filename_tex}", '-o', @filename_pdf]
            path    : @path
            cb      : (err, output) =>
                if err
                    opts.cb(err); return
                if output.stderr
                    opts.cb(output.stderr); return
                s = output.stdout
                i = s.indexOf('\nPage:')
                n = s.slice(i+6, s.indexOf('\n',i+3))
                i = s.indexOf('\nx:')
                x = parseInt(s.slice(i+3, s.indexOf('\n',i+3)))
                i = s.indexOf('\ny:')
                y = parseInt(s.slice(i+3, s.indexOf('\n',i+3)))
                opts.cb(false, {n:n, x:x, y:y})

    default_tex_command: () =>
        a = "pdflatex -synctex=1 -interact=nonstopmode "
        if @filename_tex.indexOf(' ') != -1
            a += "'#{@filename_tex}'"
        else
            a += @filename_tex
        return a

    # runs pdflatex; updates number of pages, latex log, parsed error log
    update_pdf: (opts={}) =>
        opts = defaults opts,
            status        : undefined  # status(start:'latex' or 'sage' or 'bibtex'), status(end:'latex', 'log':'output of thing running...')
            latex_command : undefined
            cb            : undefined
        @pdf_updated = true
        if not opts.latex_command?
            opts.latex_command = @default_tex_command()
        @_need_to_run = {}
        log = ''
        status = opts.status
        async.series([
            (cb) =>
                 status?(start:'latex')
                 @_run_latex opts.latex_command, (err, _log) =>
                     log += _log
                     status?(end:'latex', log:_log)
                     cb(err)
            (cb) =>
                 if @_need_to_run.sage
                     status?(start:'sage')
                     @_run_sage @_need_to_run.sage, (err, _log) =>
                         log += _log
                         status?(end:'sage', log:_log)
                         cb(err)
                 else
                     cb()
            (cb) =>
                 if @_need_to_run.bibtex
                     status?(start:'bibtex')
                     @_run_bibtex (err, _log) =>
                         status?(end:'bibtex', log:_log)
                         log += _log
                         cb(err)
                 else
                     cb()
            (cb) =>
                 if @_need_to_run.latex
                     status?(start:'latex')
                     @_run_latex opts.latex_command, (err, _log) =>
                          log += _log
                          status?(end:'latex', log:_log)
                          cb(err)
                 else
                     cb()
            (cb) =>
                 if @_need_to_run.latex
                     status?(start:'latex')
                     @_run_latex opts.latex_command, (err, _log) =>
                          log += _log
                          status?(end:'latex', log:_log)
                          cb(err)
                 else
                     cb()
        ], (err) =>
            opts.cb?(err, log))

    _run_latex: (command, cb) =>
        if not command?
            command = @default_tex_command()
        sagetex_file = @base_filename + '.sagetex.sage'
        sha_marker = 'sha1sums'
        @_exec
            command : command + "< /dev/null 2</dev/null; echo '#{sha_marker}'; sha1sum #{sagetex_file}"
            bash    : true
            timeout : 20
            err_on_exit : false
            cb      : (err, output) =>
                if err
                    cb?(err)
                else
                    i = output.stdout.lastIndexOf(sha_marker)
                    if i != -1
                        shas = output.stdout.slice(i+sha_marker.length+1)
                        output.stdout = output.stdout.slice(0,i)
                        for x in shas.split('\n')
                            v = x.split(/\s+/)
                            if v[1] == sagetex_file and v[0] != @_sagetex_file_sha
                                @_need_to_run.sage = sagetex_file
                                @_sagetex_file_sha = v[0]

                    log = output.stdout + '\n\n' + output.stderr

                    if log.indexOf('Rerun to get cross-references right') != -1
                        @_need_to_run.latex = true

                    run_sage_on = '\nRun Sage on'
                    i = log.indexOf(run_sage_on)
                    if i != -1
                        j = log.indexOf(', and then run LaTeX', i)
                        if j != -1
                            @_need_to_run.sage = log.slice(i + run_sage_on.length, j).trim()

                    i = log.indexOf("No file #{@base_filename}.bbl.")
                    if i != -1
                        @_need_to_run.bibtex = true

                    @last_latex_log = log
                    before = @num_pages
                    @_parse_latex_log_for_num_pages(log)

                    # Delete trailing removed pages from our local view of things; otherwise, they won't properly
                    # re-appear later if they look identical, etc.
                    if @num_pages < before
                        for n in [@num_pages ... before]
                            delete @_pages[n]

                    cb?(false, log)

    _run_sage: (target, cb) =>
        if not target?
            target = @base_filename + '.sagetex.sage'
        @_exec
            command : 'sage'
            args    : [target]
            timeout : 45
            cb      : (err, output) =>
                if err
                    cb?(err)
                else
                    log = output.stdout + '\n\n' + output.stderr
                    @_need_to_run.latex = true
                    cb?(false, log)

    _run_bibtex: (cb) =>
        @_exec
            command : 'bibtex'
            args    : [@base_filename]
            timeout : 10
            cb      : (err, output) =>
                if err
                    cb?(err)
                else
                    log = output.stdout + '\n\n' + output.stderr
                    @_need_to_run.latex = true
                    cb?(false, log)

    _parse_latex_log_for_num_pages: (log) =>
        i = log.indexOf("Output written")
        if i != -1
            i = log.indexOf("(", i)
            if i != -1
                j = log.indexOf(" pages", i)
                try
                    @num_pages = parseInt(log.slice(i+1,j))
                catch e
                    console.log("BUG parsing number of pages")

    # runs pdftotext; updates plain text of each page.
    # (not used right now, since we are using synctex instead...)
    update_text: (cb) =>
        @_exec
            command : "pdftotext"   # part of the "calibre" ubuntu package
            args    : [@filename_pdf, '-']
            cb      : (err, output) =>
                if not err
                    @_parse_text(output.stdout)
                cb?(err)

    trash_aux_files: (cb) =>
        EXT = ['aux', 'log', 'bbl', 'synctex.gz', 'sagetex.py', 'sagetex.sage', 'sagetex.scmd', 'sagetex.sout']
        @_exec
            command : "rm"
            args    : (@base_filename + "." + ext for ext in EXT)
            cb      : cb

    _parse_text: (text) =>
        # todo -- parse through the text file putting the pages in the correspondings @pages dict.
        # for now... for debugging.
        @_text = text
        n = 1
        for t in text.split('\x0c')  # split on form feed
            @page(n).text = t
            n += 1

    # Updates previews for a given range of pages.
    # This computes images on backend, and fills in the sha1 hashes of @pages.
    # If any sha1 hash changes from what was already there, it gets temporary
    # url for that file.
    # It assumes the pdf files is there already, and doesn't run pdflatex.
    update_images: (opts={}) =>
        opts = defaults opts,
            first_page : 1
            last_page  : undefined  # defaults to @num_pages, unless 0 in which case 99999
            cb         : undefined  # cb(err, [array of page numbers of pages that changed])
            resolution : 50         # number
            device     : '16m'      # one of '16', '16m', '256', '48', 'alpha', 'gray', 'mono'  (ignored if image_type='jpg')
            png_downscale : 2       # ignored if image type is jpg
            jpeg_quality  : 75      # jpg only -- scale of 1 to 100

        res = opts.resolution
        if @image_type == 'png'
            res /= opts.png_downscale

        if not opts.last_page?
            opts.last_page = @num_pages
            if opts.last_page == 0
                opts.last_page = 99999

        #console.log("opts.last_page = ", opts.last_page)

        if opts.first_page <= 0
            opts.first_page = 1

        if opts.last_page < opts.first_page
            # easy peasy
            opts.cb?(false,[])
            return

        tmp = undefined
        sha1_changed = []
        changed_pages = []
        pdf = undefined
        async.series([
            (cb) =>
                tmp_dir
                    project_id : @project_id
                    path       : "/tmp"
                    ttl        : 180
                    cb         : (err, _tmp) =>
                        tmp = "/tmp/#{_tmp}"
                        cb(err)
            (cb) =>
                pdf = "#{tmp}/#{@filename_pdf}"
                @_exec
                    command : 'cp'
                    args    : [@filename_pdf, pdf]
                    timeout : 15
                    err_on_exit : true
                    cb      : cb
            (cb) =>
                if @image_type == "png"
                    args = ["-r#{opts.resolution}",
                               '-dBATCH', '-dNOPAUSE',
                               "-sDEVICE=png#{opts.device}",
                               "-sOutputFile=#{tmp}/%d.png",
                               "-dFirstPage=#{opts.first_page}",
                               "-dLastPage=#{opts.last_page}",
                               "-dDownScaleFactor=#{opts.png_downscale}",
                               pdf]
                else if @image_type == "jpg"
                    args = ["-r#{opts.resolution}",
                               '-dBATCH', '-dNOPAUSE',
                               '-sDEVICE=jpeg',
                               "-sOutputFile=#{tmp}/%d.jpg",
                               "-dFirstPage=#{opts.first_page}",
                               "-dLastPage=#{opts.last_page}",
                               "-dJPEGQ=#{opts.jpeg_quality}",
                               pdf]
                else
                    cb("unknown image type #{@image_type}")
                    return

                #console.log('gs ' + args.join(" "))
                @_exec
                    command : 'gs'
                    args    : args
                    err_on_exit : true
                    timeout : 120
                    cb      : (err, output) ->
                        cb(err)

            # get the new sha1 hashes
            (cb) =>
                @_exec
                    command : "sha1sum *.png *.jpg"
                    bash    : true
                    path    : tmp
                    timeout : 15
                    cb      : (err, output) =>
                        if err
                            cb(err); return
                        for line in output.stdout.split('\n')
                            v = line.split(' ')
                            if v.length > 1
                                try
                                    filename = v[2]
                                    n = parseInt(filename.split('.')[0]) + opts.first_page - 1
                                    if @page(n).sha1 != v[0]
                                        sha1_changed.push( page_number:n, sha1:v[0], filename:filename )
                                catch e
                                    console.log("sha1sum: error parsing line=#{line}")
                        cb()

            # get the images whose sha1's changed
            (cb) =>
                #console.log("sha1_changed = ", sha1_changed)
                update = (obj, cb) =>
                    n = obj.page_number
                    salvus_client.read_file_from_project
                        project_id : @project_id
                        path       : "#{tmp}/#{obj.filename}"
                        timeout    : 5  # a single page shouldn't take long
                        cb         : (err, result) =>
                            if err
                                cb(err)
                            else if not result.url?
                                cb("no url in result for a page")
                            else
                                p = @page(n)
                                p.sha1 = obj.sha1
                                p.url = result.url
                                p.resolution = res
                                changed_pages.push(n)
                                cb()
                async.mapSeries(sha1_changed, update, cb)
        ], (err) =>
            opts.cb?(err, changed_pages)
        )

# FOR debugging only
exports.PDFLatexDocument = PDFLatexDocument

class PDF_Preview extends FileEditor
    constructor: (@editor, @filename, contents, opts) ->
        @pdflatex = new PDFLatexDocument(project_id:@editor.project_id, filename:@filename, image_type:"png")
        @opts = opts
        @_updating = false
        @element = templates.find(".salvus-editor-pdf-preview").clone()
        @spinner = @element.find(".salvus-editor-pdf-preview-spinner")
        s = path_split(@filename)
        @path = s.head
        if @path == ''
            @path = './'
        @file = s.tail
        @element.maxheight()
        @last_page = 0
        @output = @element.find(".salvus-editor-pdf-preview-page")
        @highlight = @element.find(".salvus-editor-pdf-preview-highlight").hide()
        @output.text("Loading preview...")
        @_first_output = true
        @_needs_update = true

    zoom: (opts) =>
        opts = defaults opts,
            delta : undefined
            width : undefined

        images = @output.find("img")
        if images.length == 0
            return # nothing to do

        if opts.delta?
            if not @zoom_width?
                @zoom_width = 160   # NOTE: hardcoded also in editor.css class .salvus-editor-pdf-preview-image
            max_width = @zoom_width#images.css('max-width')
            max_width += opts.delta
        else if opts.width?
            max_width = opts.width

        if max_width?
            @zoom_width = max_width
            n = @current_page().number
            margin_left = "#{-(max_width-100)/2}%"
            max_width = "#{max_width}%"
            images.css
                'max-width'   : max_width
                width         : max_width
                'margin-left' : margin_left
            @scroll_into_view(n : n, highlight_line:false, y:$(window).height()/2)

    watch_scroll: () =>
        if @_f?
            clearInterval(@_f)
        timeout = undefined
        @output.on 'scroll', () =>
            @_needs_update = true
        f = () =>
            if @_needs_update and @element.is(':visible')
                @_needs_update = false
                @update cb:(err) =>
                    if err
                        @_needs_update = true
        @_f = setInterval(f, 1000)

    highlight_middle: (fade_time) =>
        if not fade_time?
            fade_time = 5000
        @highlight.show().offset(top:$(window).height()/2)
        @highlight.stop().animate(opacity:.3).fadeOut(fade_time)

    scroll_into_view: (opts) =>
        opts = defaults opts,
            n              : required   # page
            y              : 0          # y-coordinate on page
            highlight_line : true
        pg = @pdflatex.page(opts.n)
        if not pg?
            # the page has vanished in the meantime...
            return
        t = @output.offset().top
        @output.scrollTop(0)  # reset to 0 first so that pg.element.offset().top is correct below
        top = (pg.element.offset().top + opts.y) - $(window).height() / 2
        @output.scrollTop(top)
        if opts.highlight_line
            # highlight location of interest
            @highlight_middle()

    remove: () =>
        if @_f?
            clearInterval(@_f)
        @element.remove()

    focus: () =>
        @element.maxheight()
        @output.height(@element.height())
        @output.width(@element.width())

    current_page: () =>
        tp = @output.offset().top
        for _page in @output.children()
            page = $(_page)
            offset = page.offset()
            if offset.top > tp
                n = page.data('number')
                if n > 1
                    n -= 1
                return {number:n, offset:offset.top}
        if page?
            return {number:page.data('number')}
        else
            return {number:1}

    update: (opts={}) =>
        opts = defaults opts,
            window_size : 4
            cb          : undefined

        if @_updating
            opts.cb?("already updating")  # don't change string
            return

        #@spinner.show().spin(true)
        @_updating = true

        @output.maxheight()
        if @element.width()
            @output.width(@element.width())

        # Remove trailing pages from DOM.
        if @pdflatex.num_pages?
            # This is O(N), but behaves better given the async nature...
            for p in @output.children()
                page = $(p)
                if page.data('number') > @pdflatex.num_pages
                    page.remove()

        n = @current_page().number

        f = (opts, cb) =>
            opts.cb = (err, changed_pages) =>
                if err
                    cb(err)
                else if changed_pages.length == 0
                    cb()
                else
                    g = (n, cb) =>
                        @_update_page(n, cb)
                    async.map(changed_pages, g, cb)
            @pdflatex.update_images(opts)

        hq_window = opts.window_size
        if n == 1
            hq_window *= 2

        f {first_page : n, last_page  : n+1, resolution:@opts.resolution*3, device:'16m', png_downscale:3}, (err) =>
            if err
                #@spinner.spin(false).hide()
                @_updating = false
                opts.cb?(err)
            else if not @pdflatex.pdf_updated? or @pdflatex.pdf_updated
                @pdflatex.pdf_updated = false
                g = (obj, cb) =>
                    if obj[2]
                        f({first_page:obj[0], last_page:obj[1], resolution:'300', device:'16m', png_downscale:3}, cb)
                    else
                        f({first_page:obj[0], last_page:obj[1], resolution:'150', device:'gray', png_downscale:1}, cb)
                v = []
                v.push([n-hq_window, n-1, true])
                v.push([n+2, n+hq_window, true])

                k1 = Math.round((1 + n-hq_window-1)/2)
                v.push([1, k1])
                v.push([k1+1, n-hq_window-1])
                if @pdflatex.num_pages
                    k2 = Math.round((n+hq_window+1 + @pdflatex.num_pages)/2)
                    v.push([n+hq_window+1,k2])
                    v.push([k2,@pdflatex.num_pages])
                else
                    v.push([n+hq_window+1,999999])
                async.map v, g, (err) =>
                    #@spinner.spin(false).hide()
                    @_updating = false

                    # If first time, start watching for scroll movements to update.
                    if not @_f?
                        @watch_scroll()
                    opts.cb?()
            else
                @_updating = false
                opts.cb?()


    # update page n based on currently computed data.
    _update_page: (n, cb) =>
        p          = @pdflatex.page(n)
        url        = p.url
        resolution = p.resolution
        if not url?
            # delete page and all following it from DOM
            for m in [n .. @last_page]
                @output.remove(".salvus-editor-pdf-preview-page-#{m}")
            if @last_page >= n
                @last_page = n-1
        else
            # update page
            that = @
            page = @output.find(".salvus-editor-pdf-preview-page-#{n}")
            if page.length == 0
                # create
                for m in [@last_page+1 .. n]
                    #page = $("<div style='text-align:center;' class='salvus-editor-pdf-preview-page-#{m}'><div class='salvus-editor-pdf-preview-text'></div><img alt='Page #{m}' class='salvus-editor-pdf-preview-image img-rounded'><br></div>")
                    page = $("<div style='text-align:center;' class='salvus-editor-pdf-preview-page-#{m}'><img alt='Page #{m}' class='salvus-editor-pdf-preview-image img-rounded'><br></div>")
                    page.data("number", m)

                    f = (e) ->
                        pg = $(e.delegateTarget)
                        n  = pg.data('number')
                        offset = $(e.target).offset()
                        x = e.pageX - offset.left
                        y = e.pageY - offset.top
                        img = pg.find("img")
                        nH = img[0].naturalHeight
                        nW = img[0].naturalWidth
                        y *= nH/img.height()
                        x *= nW/img.width()
                        that.emit 'shift-click', {n:n, x:x, y:y, resolution:img.data('resolution')}
                        return false

                    page.click (e) ->
                        if e.shiftKey or e.ctrlKey
                            f(e)
                        return false

                    page.dblclick(f)

                    if self._margin_left?
                        # A zoom was set via the zoom command -- maintain it.
                        page.find("img").css
                            'max-width'   : self._max_width
                            width         : self._max_width
                            'margin-left' : self._margin_left

                    if @_first_output
                        @output.empty()
                        @_first_output = false

                    # Insert page in the right place in the output.  Since page creation
                    # can happen in parallel/random order (esp because of deletes of trailing pages),
                    # we have to work at this a bit.
                    done = false
                    for p in @output.children()
                        pg = $(p)
                        if pg.data('number') > m
                            page.insertBefore(pg)
                            done = true
                            break
                    if not done
                        @output.append(page)

                    @pdflatex.page(m).element = page

                @last_page = n
            img =  page.find("img")
            #console.log("setting an img src to", url)
            img.attr('src', url).data('resolution', resolution)
            load_error = () ->
                img.off('error', load_error)
                setTimeout((()->img.attr('src',url)), 2000)
            img.on('error', load_error)

            if @zoom_width?
                max_width = @zoom_width
                margin_left = "#{-(max_width-100)/2}%"
                max_width = "#{max_width}%"
                img.css
                    'max-width'   : max_width
                    width         : max_width
                    'margin-left' : margin_left

            #page.find(".salvus-editor-pdf-preview-text").text(p.text)
        cb()

    show: (geometry={}) =>
        geometry = defaults geometry,
            left   : undefined
            top    : undefined
            width  : $(window).width()
            height : undefined

        @element.show()

        f = () =>
            @element.width(geometry.width)
            @element.offset
                left : geometry.left
                top  : geometry.top

            if geometry.height?
                @element.height(geometry.height)
            else
                @element.maxheight()
                geometry.height = @element.height()

            @focus()
        # We wait a tick for the element to appear before positioning it, otherwise it
        # can randomly get messed up.
        setTimeout(f, 1)

    hide: () =>
        @element.hide()


class PDF_PreviewEmbed extends FileEditor
    constructor: (@editor, @filename, contents, @opts) ->
        @element = templates.find(".salvus-editor-pdf-preview-embed").clone()
        @element.find(".salvus-editor-pdf-title").text(@filename)

        @spinner = @element.find(".salvus-editor-pdf-preview-embed-spinner")

        s = path_split(@filename)
        @path = s.head
        if @path == ''
            @path = './'
        @file = s.tail

        @output = @element.find(".salvus-editor-pdf-preview-embed-page")

        @element.find("a[href=#refresh]").click () =>
            @update()
            return false

    focus: () =>

    update: (cb) =>
        height = @element.height()
        if height == 0
            # not visible.
            return
        width = @element.width()

        button = @element.find("a[href=#refresh]")
        button.icon_spin(true)

        @_last_width = width
        @_last_height = height

        output_height = height - ( @output.offset().top - @element.offset().top)
        @output.height(output_height)
        @output.width(width)

        @spinner.show().spin(true)
        salvus_client.read_file_from_project
            project_id : @editor.project_id
            path       : @filename
            timeout    : 20
            cb         : (err, result) =>
                button.icon_spin(false)
                @spinner.spin(false).hide()
                if err or not result.url?
                    alert_message(type:"error", message:"unable to get pdf -- #{err}")
                else
                    @output.html("<object data='#{result.url}' type='application/pdf' width='#{width}' height='#{output_height-10}'><br><br>Your browser doesn't support embedded PDF's, but you can <a href='#{result.url}'>download #{@filename}</a></p></object>")

    show: (geometry={}) =>
        geometry = defaults geometry,
            left   : undefined
            top    : undefined
            width  : $(window).width()
            height : undefined

        @element.show()

        if geometry.height?
            @element.height(geometry.height)
        else
            @element.maxheight()
            geometry.height = @element.height()

        @element.width(geometry.width)

        @element.offset
            left : geometry.left
            top  : geometry.top

        if @_last_width != geometry.width or @_last_height != geometry.height
            @update()

        @focus()

    hide: () =>
        @element.hide()


class LatexEditor extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        # The are three components:
        #     * latex_editor -- a CodeMirror editor
        #     * preview -- display the images (page forward/backward/resolution)
        #     * log -- log of latex command
        opts.mode = 'stex'
        opts.geometry = 'left half'

        @element = templates.find(".salvus-editor-latex").clone()

        @_pages = {}

        # initialize the latex_editor
        @latex_editor = codemirror_session_editor(@editor, filename, opts)
        @_pages['latex_editor'] = @latex_editor
        @element.find(".salvus-editor-latex-latex_editor").append(@latex_editor.element)
        @latex_editor.action_key = @action_key
        @element.find(".salvus-editor-latex-buttons").show()

        @latex_editor.on 'show', () =>
            @show_page()

        @latex_editor.syncdoc.on 'connect', () =>
            @preview.zoom_width = @load_conf().zoom_width
            @update_preview()

        v = path_split(@filename)
        @_path = v.head
        @_target = v.tail

        # initialize the previews
        n = @filename.length

        # The pdf preview.
        @preview = new PDF_Preview(@editor, @filename, undefined, {resolution:200})
        @element.find(".salvus-editor-latex-png-preview").append(@preview.element)
        @_pages['png-preview'] = @preview
        @preview.on 'shift-click', (opts) => @_inverse_search(opts)

        # Embedded pdf page (not really a "preview" -- it's the real thing).
        @preview_embed = new PDF_PreviewEmbed(@editor, @filename.slice(0,n-3)+"pdf", undefined, {})
        @element.find(".salvus-editor-latex-pdf-preview").append(@preview_embed.element)
        @preview_embed.element.find(".salvus-editor-pdf-title").hide()
        @preview_embed.element.find("a[href=#refresh]").hide()
        @_pages['pdf-preview'] = @preview_embed

        # initalize the log
        @log = @element.find(".salvus-editor-latex-log")
        @log.find("a").tooltip(delay:{ show: 500, hide: 100 })
        @_pages['log'] = @log
        @log_input = @log.find("input")
        @log_input.keyup (e) =>
            if e.keyCode == 13
                latex_command = @log_input.val()
                @set_conf(latex_command: latex_command)
                @save()

        @errors = @element.find(".salvus-editor-latex-errors")
        @_pages['errors'] = @errors
        @_error_message_template = @element.find(".salvus-editor-latex-mesg-template")

        @_init_buttons()

        # This synchronizes the editor and png preview -- it's kind of disturbing.
        # If people request it, make it a non-default option...
        if false
            @preview.output.on 'scroll', @_passive_inverse_search
            cm0 = @latex_editor.codemirror
            cm1 = @latex_editor.codemirror1
            cm0.on 'cursorActivity', @_passive_forward_search
            cm1.on 'cursorActivity', @_passive_forward_search
            cm0.on 'change', @_pause_passive_search
            cm1.on 'change', @_pause_passive_search

    set_conf: (obj) =>
        conf = @load_conf()
        for k, v of obj
            conf[k] = v
        @save_conf(conf)

    load_conf: () =>
        doc = @latex_editor.codemirror.getValue()
        i = doc.indexOf("%sagemathcloud=")
        if i == -1
            return {}

        j = doc.indexOf('=',i)
        k = doc.indexOf('\n',i)
        if k == -1
            k = doc.length
        try
            conf = misc.from_json(doc.slice(j+1,k))
        catch
            conf = {}

        return conf

    save_conf: (conf) =>
        cm  = @latex_editor.codemirror
        doc = cm.getValue()
        i = doc.indexOf('%sagemathcloud=')
        line = '%sagemathcloud=' + misc.to_json(conf)
        if i != -1
            # find the line m where it is already
            for n in [0..cm.doc.lastLine()]
                z = cm.getLine(n)
                if z.indexOf('%sagemathcloud=') != -1
                    m = n
                    break
            cm.setLine(m, line)
        else
            cm.replaceRange('\n'+line, {line:cm.doc.lastLine()+1,ch:0})
        @latex_editor.syncdoc.sync()

    _pause_passive_search: (cb) =>
        @_passive_forward_search_disabled = true
        @_passive_inverse_search_disabled = true
        f = () =>
            @_passive_inverse_search_disabled = false
            @_passive_forward_search_disabled = false

        setTimeout(f, 3000)


    _passive_inverse_search: (cb) =>
        if @_passive_inverse_search_disabled
            cb?(); return
        @_pause_passive_search()
        @inverse_search
            active : false
            cb     : (err) =>
                cb?()

    _passive_forward_search: (cb) =>
        if @_passive_forward_search_disabled
            cb?(); return
        @forward_search
            active : false
            cb     : (err) =>
                @_pause_passive_search()
                cb?()

    action_key: () =>
        @show_page('png-preview')
        @forward_search(active:true)

    remove: () =>
        @element.remove()
        @preview.remove()
        @preview_embed.remove()

    _init_buttons: () =>
        @element.find("a").tooltip(delay:{ show: 500, hide: 100 } )

        @element.find("a[href=#forward-search]").click () =>
            @show_page('png-preview')
            @forward_search(active:true)
            return false

        @element.find("a[href=#inverse-search]").click () =>
            @show_page('png-preview')
            @inverse_search(active:true)
            return false

        @element.find("a[href=#png-preview]").click () =>
            @show_page('png-preview')
            @preview.focus()
            @save()
            return false

        @element.find("a[href=#zoom-preview-out]").click () =>
            @preview.zoom(delta:-5)
            @set_conf(zoom_width:@preview.zoom_width)
            return false

        @element.find("a[href=#zoom-preview-in]").click () =>
            @preview.zoom(delta:5)
            @set_conf(zoom_width:@preview.zoom_width)
            return false

        @element.find("a[href=#zoom-preview-fullpage]").click () =>
            @preview.zoom(width:100)
            @set_conf(zoom_width:@preview.zoom_width)
            return false

        @element.find("a[href=#zoom-preview-width]").click () =>
            @preview.zoom(width:160)
            @set_conf(zoom_width:@preview.zoom_width)
            return false


        @element.find("a[href=#pdf-preview]").click () =>
            @show_page('pdf-preview')
            @preview_embed.focus()
            @preview_embed.update()
            return false

        @element.find("a[href=#log]").click () =>
            @show_page('log')
            @element.find(".salvus-editor-latex-log").find("textarea").maxheight()
            t = @log.find("textarea")
            t.scrollTop(t[0].scrollHeight)
            return false

        @element.find("a[href=#errors]").click () =>
            @show_page('errors')
            return false

        @number_of_errors = @element.find("a[href=#errors]").find(".salvus-latex-errors-counter")
        @number_of_warnings = @element.find("a[href=#errors]").find(".salvus-latex-warnings-counter")

        @element.find("a[href=#pdf-download]").click () =>
            @download_pdf()
            return false

        @element.find("a[href=#preview-resolution]").click () =>
            @set_resolution()
            return false

        @element.find("a[href=#latex-command-undo]").click () =>
            c = @preview.pdflatex.default_tex_command()
            @log_input.val(c)
            @set_conf(latex_command: c)
            return false

        trash_aux_button = @element.find("a[href=#latex-trash-aux]")
        trash_aux_button.click () =>
            trash_aux_button.icon_spin(true)
            @preview.pdflatex.trash_aux_files () =>
                trash_aux_button.icon_spin(false)
            return false

        run_sage = @element.find("a[href=#latex-sage]")
        run_sage.click () =>
            @log.find("textarea").text("Running Sage...")
            run_sage.icon_spin(true)
            @preview.pdflatex._run_sage undefined, (err, log) =>
                run_sage.icon_spin(false)
                @log.find("textarea").text(log)
            return false

        run_latex = @element.find("a[href=#latex-latex]")
        run_latex.click () =>
            @log.find("textarea").text("Running Latex...")
            run_latex.icon_spin(true)
            @preview.pdflatex._run_latex @load_conf().latex_command, (err, log) =>
                run_latex.icon_spin(false)
                @log.find("textarea").text(log)
            return false

        run_bibtex = @element.find("a[href=#latex-bibtex]")
        run_bibtex.click () =>
            @log.find("textarea").text("Running Bibtex...")
            run_bibtex.icon_spin(true)
            @preview.pdflatex._run_bibtex (err, log) =>
                run_bibtex.icon_spin(false)
                @log.find("textarea").text(log)
            return false


    set_resolution: (res) =>
        if not res?
            bootbox.prompt "Change preview resolution from #{@get_resolution()} dpi to...", (result) =>
                if result
                    @set_resolution(result)
        else
            try
                res = parseInt(res)
                if res < 150
                    res = 150
                else if res > 600
                    res = 600
                @preview.opts.resolution = res
                @preview.update()
            catch e
                alert_message(type:"error", message:"Invalid resolution #{res}")

    get_resolution: () =>
        return @preview.opts.resolution


    click_save_button: () =>
        @latex_editor.click_save_button()

    save: (cb) =>
        @latex_editor.save (err) =>
            cb?(err)
            if not err
                @update_preview () =>
                    if @_current_page == 'pdf-preview'
                        @preview_embed.update()


    update_preview: (cb) =>
        @run_latex
            command : @load_conf().latex_command
            cb      : () =>
                @preview.update
                    cb: (err) =>
                        cb?(err)

    _get: () =>
        return @latex_editor._get()

    _set: (content) =>
        @latex_editor._set(content)

    show: () =>
        @element?.show()
        @latex_editor?.show()
        if not @_show_before?
            @show_page('png-preview')
            @_show_before = true

    focus: () =>
        @latex_editor?.focus()

    has_unsaved_changes: (val) =>
        return @latex_editor?.has_unsaved_changes(val)

    show_page: (name) =>
        if not name?
            name = @_current_page
        @_current_page = name
        if not name?
            name = 'png-preview'

        pages = ['png-preview', 'pdf-preview', 'log', 'errors']
        for n in pages
            @element.find(".salvus-editor-latex-#{n}").hide()

        for n in pages
            page = @_pages[n]
            e = @element.find(".salvus-editor-latex-#{n}")
            button = @element.find("a[href=#" + n + "]")
            if n == name
                e.show()
                es = @latex_editor.empty_space
                g  = left : es.start, top:es.top+3, width:es.end-es.start-3
                if n not in ['log', 'errors']
                    page.show(g)
                else
                    page.offset({left:g.left, top:g.top}).width(g.width)
                    page.maxheight()
                    if n == 'log'
                        c = @load_conf().latex_command
                        if c
                            @log_input.val(c)
                    else if n == 'errors'
                        @render_error_page()
                button.addClass('btn-primary')
            else
                button.removeClass('btn-primary')

    run_latex: (opts={}) =>
        opts = defaults opts,
            command : undefined
            cb      : undefined
        button = @element.find("a[href=#log]")
        button.icon_spin(true)
        log_output = @log.find("textarea")
        log_output.text("")
        if not opts.command?
            opts.command = @preview.pdflatex.default_tex_command()
        @log_input.val(opts.command)

        build_status = button.find(".salvus-latex-build-status")
        status = (mesg) =>
            if mesg.start
                build_status.text(' - ' + mesg.start)
                log_output.text(log_output.text() + '\n\n-----------------------------------------------------\nRunning ' + mesg.start + '...\n\n\n\n')
            else
                if mesg.end == 'latex'
                    @render_error_page()
                build_status.text('')
                log_output.text(log_output.text() + '\n' + mesg.log + '\n')
            # Scroll to the bottom of the textarea
            log_output.scrollTop(log_output[0].scrollHeight)

        @preview.pdflatex.update_pdf
            status        : status
            latex_command : opts.command
            cb            : (err, log) =>
                button.icon_spin(false)
                opts.cb?()

    render_error_page: () =>
        log = @preview.pdflatex.last_latex_log
        if not log?
            return
        p = (new LatexParser(log)).parse()

        if p.errors.length
            @number_of_errors.text(p.errors.length)
            @element.find("a[href=#errors]").addClass("btn-danger")
        else
            @number_of_errors.text('')
            @element.find("a[href=#errors]").removeClass("btn-danger")

        k = p.warnings.length + p.typesetting.length
        if k
            @number_of_warnings.text("(#{k})")
        else
            @number_of_warnings.text('')

        if @_current_page != 'errors'
            return

        elt = @errors.find(".salvus-latex-errors")
        if p.errors.length == 0
            elt.html("None")
        else
            elt.html("")
            for mesg in p.errors
                elt.append(@render_error_message(mesg))

        elt = @errors.find(".salvus-latex-warnings")
        if p.warnings.length == 0
            elt.html("None")
        else
            elt.html("")
            for mesg in p.warnings
                elt.append(@render_error_message(mesg))

        elt = @errors.find(".salvus-latex-typesetting")
        if p.typesetting.length == 0
            elt.html("None")
        else
            elt.html("")
            for mesg in p.typesetting
                elt.append(@render_error_message(mesg))

    _show_error_in_file: (mesg, cb) =>
        file = mesg.file
        if not file
            alert_message(type:"error", "No way to open unknown file.")
            cb?()
            return
        if not mesg.line
            if mesg.page
                @_inverse_search
                    n : mesg.page
                    active : false
                    x : 50
                    y : 50
                    resolution:200
                    cb: cb
            else
                alert_message(type:"error", "Unknown location in '#{file}'.")
                cb?()
                return
        else
            if @preview.pdflatex.filename_tex == file
                @latex_editor.set_cursor_center_focus({line:mesg.line-1, ch:0})
            else
                @editor.open file, (err, fname) =>
                    if not err
                        @editor.display_tab(path:fname)
                        # TODO: need to set position, right?
                        # also, as in _inverse_search -- maybe this should be opened *inside* the latex editor...
            cb?()

    _show_error_in_preview: (mesg) =>
        if @preview.pdflatex.filename_tex == mesg.file
            @_show_error_in_file mesg, () =>
                @show_page('png-preview')
                @forward_search(active:true)

    render_error_message: (mesg) =>

        if not mesg.line
            r = mesg.raw
            i = r.lastIndexOf('[')
            j = i+1
            while j < r.length and r[j] >= '0' and r[j] <= '9'
                j += 1
            mesg.page = r.slice(i+1,j)

        if mesg.file.slice(0,2) == './'
            mesg.file = mesg.file.slice(2)

        elt = @_error_message_template.clone().show()
        elt.find("a:first").click () =>
            @_show_error_in_file(mesg)
            return false
        elt.find("a:last").click () =>
            @_show_error_in_preview(mesg)
            return false

        elt.addClass("salvus-editor-latex-mesg-template-#{mesg.level}")
        if mesg.line
            elt.find(".salvus-latex-mesg-line").text("line #{mesg.line}").data('line', mesg.line)
        if mesg.page
            elt.find(".salvus-latex-mesg-page").text("page #{mesg.page}").data('page', mesg.page)
        if mesg.file
            elt.find(".salvus-latex-mesg-file").text(" of #{mesg.file}").data('file', mesg.file)
        if mesg.message
            elt.find(".salvus-latex-mesg-message").text(mesg.message)
        if mesg.content
            elt.find(".salvus-latex-mesg-content").show().text(mesg.content)
        return elt


    download_pdf: () =>
        button = @element.find("a[href=#pdf-download]")
        button.icon_spin(true)
        # TODO: THIS replicates code in project.coffee
        salvus_client.read_file_from_project
            project_id : @editor.project_id
            path       : @filename.slice(0,@filename.length-3)+"pdf"
            timeout    : 45
            cb         : (err, result) =>
                button.icon_spin(false)
                if err
                    alert_message(type:"error", message:"Error downloading PDF: #{err} -- #{misc.to_json(result)}")
                else
                    url = result.url + "&download"
                    iframe = $("<iframe>").addClass('hide').attr('src', url).appendTo($("body"))
                    setTimeout((() -> iframe.remove()), 1000)

    _inverse_search: (opts) =>
        active = opts.active  # whether user actively clicked, in which case we may open a new file -- otherwise don't open anything.
        delete opts.active
        cb = opts.cb
        opts.cb = (err, res) =>
            if err
                if active
                    alert_message(type:"error", message: "Inverse search error -- #{err}")
            else
                if res.input != @filename
                    if active
                        @editor.open res.input, (err, fname) =>
                            if not err
                                @editor.display_tab(path:fname)
                                # TODO: need to set position, right?
                else
                    @latex_editor.set_cursor_center_focus({line:res.line, ch:0})
            cb?()

        @preview.pdflatex.inverse_search(opts)

    inverse_search: (opts={}) =>
        opts = defaults opts,
            active : required
            cb     : undefined
        number = @preview.current_page().number
        elt    = @preview.pdflatex.page(number).element
        output = @preview.output
        nH     = elt.find("img")[0].naturalHeight
        y      = (output.height()/2 + output.offset().top - elt.offset().top) * nH / elt.height()
        @_inverse_search({n:number, x:0, y:y, resolution:@preview.pdflatex.page(number).resolution, cb:opts.cb})

    forward_search: (opts={}) =>
        opts = defaults opts,
            active : true
            cb     : undefined
        cm = @latex_editor.codemirror_with_last_focus
        if not cm?
            opts.cb?()
            return
        n = cm.getCursor().line + 1
        @preview.pdflatex.forward_search
            n  : n
            cb : (err, result) =>
                if err
                    if opts.active
                        alert_message(type:"error", message:err)
                else
                    y = result.y
                    pg = @preview.pdflatex.page(result.n)
                    res = pg.resolution
                    img = pg.element?.find("img")
                    if not img?
                        opts.cb?("Page #{result.n} not yet loaded.")
                        return
                    nH = img[0].naturalHeight
                    if not res?
                        y = 0
                    else
                        y *= res / 72 * img.height() / nH
                    @preview.scroll_into_view
                        n              : result.n
                        y              : y
                        highlight_line : true
                opts.cb?(err)

class Terminal extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        @element = $("<div>").hide()
        salvus_client.read_text_file_from_project
            project_id : @editor.project_id
            path       : @filename
            cb         : (err, result) =>
                if err
                    alert_message(type:"error", message: "Error connecting to console server.")
                else
                    # New session or connect to session
                    if result.content? and result.content.length < 36
                        # empty/corrupted -- messed up by bug in early version of SMC...
                        delete result.content
                    opts = @opts = defaults opts,
                        session_uuid : result.content
                        rows         : 24
                        cols         : 80

                    elt = @element.salvus_console
                        title   : "Terminal"
                        filename : filename
                        cols    : @opts.cols
                        rows    : @opts.rows
                        resizable: false
                        close   : () => @editor.project_page.display_tab("project-file-listing")
                        editor  : @editor
                    @console = elt.data("console")
                    @element = @console.element
                    @connect_to_server()

    connect_to_server: (cb) =>
        mesg =
            timeout    : 30  # just for making the connection; not the timeout of the session itself!
            type       : 'console'
            project_id : @editor.project_id
            cb : (err, session) =>
                if err
                    alert_message(type:'error', message:err)
                    cb?(err)
                else
                    if @element.is(":visible")
                        @show()
                    @console.set_session(session)
                    salvus_client.write_text_file_to_project
                        project_id : @editor.project_id
                        path       : @filename
                        content    : session.session_uuid
                        cb         : cb

        path = misc.path_split(@filename).head
        mesg.params  = {command:'bash', rows:@opts.rows, cols:@opts.cols, path:path}
        if @opts.session_uuid?
            mesg.session_uuid = @opts.session_uuid
            salvus_client.connect_to_session(mesg)
        else
            salvus_client.new_session(mesg)

        # TODO
        #@filename_tab.set_icon('console')


    _get: () =>  # TODO
        return 'history saving not yet implemented'

    _set: (content) =>  # TODO

    focus: () =>
        @console?.focus()

    terminate_session: () =>
        #@console?.terminate_session()
        @local_storage("auto_open", false)

    remove: () =>
        @element.salvus_console(false)
        @element.remove()

    show: () =>
        @element.show()
        if @console?
            e = $(@console.terminal.element)
            top = @editor.editor_top_position() + @element.find(".salvus-console-topbar").height()
            # We leave a gap at the bottom of the screen, because often the
            # cursor is at the bottom, but tooltips, etc., would cover that
            ht = $(window).height() - top - 6
            if feature.isMobile.iOS()
                ht = Math.floor(ht/2)
            e.height(ht)
            @element.css(top:@editor.editor_top_position(), position:'fixed')   # TODO: this is hack-ish; needs to be redone!
            @console.focus(true)

class Worksheet extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        opts = @opts = defaults opts,
            session_uuid : undefined
        @element = $("<div>Opening worksheet...</div>")  # TODO -- make much nicer
        if content?
            @_set(content)
        else
            salvus_client.read_text_file_from_project
                project_id : @editor.project_id
                timeout    : 40
                path       : filename
                cb         : (err, mesg) =>
                    if err
                        alert_message(type:"error", message:"Communications issue loading worksheet #{@filename} -- #{err}")
                    else if mesg.event == 'error'
                        alert_message(type:"error", message:"Error loading worksheet #{@filename} -- #{to_json(mesg.error)}")
                    else
                        @_set(mesg.content)

    connect_to_server: (session_uuid, cb) =>
        if @session?
            cb('already connected or attempting to connect')
            return
        @session = "init"
        async.series([
            (cb) =>
                # If the worksheet specifies a specific session_uuid,
                # try to connect to that one, in case it is still
                # running.
                if session_uuid?
                    salvus_client.connect_to_session
                        type         : 'sage'
                        timeout      : 60
                        project_id   : @editor.project_id
                        session_uuid : session_uuid
                        cb           : (err, _session) =>
                            if err or _session.event == 'error'
                                # NOPE -- try to make a new session (below)
                                cb()
                            else
                                # Bingo -- got it!
                                @session = _session
                                cb()
                else
                    # No session_uuid requested.
                    cb()
            (cb) =>
                if @session? and @session != "init"
                    # We successfully got a session above.
                    cb()
                else
                    # Create a completely new session on the given project.
                    salvus_client.new_session
                        timeout    : 60
                        type       : "sage"
                        project_id : @editor.project_id
                        cb : (err, _session) =>
                            if err
                                @element.text(err)  # TODO -- nicer
                                alert_message(type:'error', message:err)
                                @session = undefined
                            else
                                @session = _session
                            cb(err)
        ], cb)

    _get: () =>
        if @worksheet?
            obj = @worksheet.to_obj()
            # Make JSON nice, so more human readable *and* more diff friendly (for git).
            return JSON.stringify(obj, null, '\t')
        else
            return undefined

    _set: (content) =>
        content = $.trim(content)
        if content.length > 0
            {content, session_uuid} = from_json(content)
        else
            content = undefined
            session_uuid = undefined

        @connect_to_server session_uuid, (err) =>
            if err
                return
            @element.salvus_worksheet
                content     : content
                path        : @filename
                session     : @session
                project_id  : @editor.project_id
                cwd         : misc.path_split(@editor.project_path + '/' + @filename).head

            @worksheet = @element.data("worksheet")
            @worksheet.save(@filename)
            @element   = @worksheet.element
            @worksheet.on 'save', (new_filename) =>
                if new_filename != @filename
                    @editor.change_tab_filename(@filename, new_filename)
                    @filename = new_filename

            @worksheet.on 'change', () =>
                @has_unsaved_changes(true)

    focus: () =>
        if not IS_MOBILE
            @worksheet?.focus()

    show: () =>
        if not @worksheet?
            return
        @element.show()
        win = $(window)
        @element.width(win.width())
        top = @editor.editor_top_position()
        @element.css(top:top)
        if top == 0
            @element.css('position':'fixed')
            @element.find(".salvus-worksheet-filename").hide()
            @element.find(".salvus-worksheet-controls").hide()
            @element.find(".salvus-cell-checkbox").hide()
            # TODO: redo these three by adding/removing a CSS class!
            input = @element.find(".salvus-cell-input")
            @_orig_css_input =
                'font-size' : input.css('font-size')
                'line-height' : input.css('line-height')
            input.css
                'font-size':'11pt'
                'line-height':'1.1em'
            output = @element.find(".salvus-cell-output")
            @_orig_css_input =
                'font-size' : output.css('font-size')
                'line-height' : output.css('line-height')
            output.css
                'font-size':'11pt'
                'line-height':'1.1em'
        else
            @element.find(".salvus-worksheet-filename").show()
            @element.find(".salvus-worksheet-controls").show()
            @element.find(".salvus-cell-checkbox").show()
            if @_orig_css_input?
                @element.find(".salvus-cell-input").css(@_orig_css_input)
                @element.find(".salvus-cell-output").css(@_orig_css_output)

        @element.height(win.height() - top)
        if top > 0
            bar_height = @element.find(".salvus-worksheet-controls").height()
            @element.find(".salvus-worksheet-worksheet").height(win.height() - top - bar_height)
        else
            @element.find(".salvus-worksheet-worksheet").height(win.height())

    disconnect_from_session : (cb) =>
        # We define it this way for now, since we don't have sync yet.
        @worksheet?.save()
        cb?()


class Image extends FileEditor
    constructor: (@editor, @filename, url, opts) ->
        opts = @opts = defaults opts,{}
        @element = templates.find(".salvus-editor-image").clone()
        @element.find(".salvus-editor-image-title").text(@filename)

        refresh = @element.find("a[href=#refresh]")
        refresh.click () =>
            refresh.icon_spin(true)
            @update (err) =>
                refresh.icon_spin(false)
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

        if url?
            @element.find(".salvus-editor-image-container").find("span").hide()
            @element.find("img").attr('src', url)
        else
            @update()

    update: (cb) =>
        @element.find("a[href=#refresh]").icon_spin(start:true)
        salvus_client.read_file_from_project
            project_id : @editor.project_id
            timeout    : 30
            path       : @filename
            cb         : (err, mesg) =>
                @element.find("a[href=#refresh]").icon_spin(false)
                @element.find(".salvus-editor-image-container").find("span").hide()
                if err
                    alert_message(type:"error", message:"Communications issue loading #{@filename} -- #{err}")
                    cb?(err)
                else if mesg.event == 'error'
                    alert_message(type:"error", message:"Error getting #{@filename} -- #{to_json(mesg.error)}")
                    cb?(mesg.event)
                else
                    @element.find("img").attr('src', mesg.url)
                    cb?()

    show: () =>
        @element.show()
        @element.maxheight()


#**************************************************
# IPython Support
#**************************************************

ipython_notebook_server = (opts) ->
    opts = defaults opts,
        project_id : required
        path       : required   # directory from which the files are served
        cb         : required   # cb(err, server)

    I = new IPythonNotebookServer(opts.project_id, opts.path)
    I.start_server (err, base) =>
        opts.cb(err, I)

class IPythonNotebookServer  # call ipython_notebook_server above
    constructor: (@project_id, @path) ->

    start_server: (cb) =>
        salvus_client.exec
            project_id : @project_id
            path       : @path
            command    : "ipython-notebook"
            args       : ['start']
            bash       : false
            timeout    : 10
            err_on_exit: false
            cb         : (err, output) =>
                if err
                    cb?(err)
                else
                    try
                        info = misc.from_json(output.stdout)
                        if info.error?
                            cb?(info.error)
                        else
                            @url = info.base; @pid = info.pid; @port = info.port
                            get_with_retry
                                url : @url
                                cb  : (err, data) =>
                                    cb?(err)
                    catch e
                        cb?(true)

    notebooks: (cb) =>  # cb(err, [{kernel_id:?, name:?, notebook_id:?}, ...]  # kernel_id is null if not running
        get_with_retry
            url : @url + 'notebooks'
            cb  : (err, data) =>
                if not err
                    cb(false, misc.from_json(data))
                else
                    cb(err)

    stop_server: (cb) =>
        if not @pid?
            cb?(); return
        salvus_client.exec
            project_id : @project_id
            path       : @path
            command    : "ipython-notebook"
            args       : ['stop']
            bash       : false
            timeout    : 15
            cb         : (err, output) =>
                cb?(err)

# Download a remote URL, possibly retrying repeatedly with exponetial backoff, only failing
# if the delay until next retry hits max_delay.
# If the downlaod URL contains bad_string (default: 'ECONNREFUSED'), also retry.
get_with_retry = (opts) ->
    opts = defaults opts,
        url           : required
        initial_delay : 50
        max_delay     : 15000     # once delay hits this, give up
        factor        : 1.1      # for exponential backoff
        bad_string    : 'ECONNREFUSED'
        cb            : required  # cb(err, data)  # data = content of that url
    delay = opts.initial_delay
    f = () =>
        if delay >= opts.max_delay  # too many attempts
            opts.cb("unable to connect to remote server")
            return
        $.ajax(
            url     : opts.url
            timeout : 50
            success : (data) ->
                if data.indexOf(opts.bad_string) != -1
                    delay *= opts.factor
                    setTimeout(f, delay)
                else
                    opts.cb(false, data)
        ).fail(() ->
            delay *= opts.factor
            setTimeout(f, delay)
        )

    f()


# Embedded editor for editing IPython notebooks.  Enhanced with sync and integrated into the
# overall cloud look.
class IPythonNotebook extends FileEditor
    constructor: (@editor, @filename, url, opts) ->
        opts = @opts = defaults opts,
            sync_interval : 500
            cursor_interval : 2000
        @element = templates.find(".salvus-ipython-notebook").clone()

        @_start_time = misc.walltime()
        if window.salvus_base_url != ""
            # TODO: having a base_url doesn't imply necessarily that we're in a dangerous devel mode...
            # (this is just a warning).
            # The solutiion for this issue will be to set a password whenever ipython listens on localhost.
            @element.find(".salvus-ipython-notebook-danger").show()
            setTimeout( ( () => @element.find(".salvus-ipython-notebook-danger").hide() ), 3000)

        @status_element = @element.find(".salvus-ipython-notebook-status-messages")
        @init_buttons()
        s = path_split(@filename)
        @path = s.head
        @file = s.tail

        if @path
            @syncdoc_filename = @path + '/.' + @file + ".syncdoc"
        else
            @syncdoc_filename = '.' + @file + ".syncdoc"

        # This is where we put the page itself
        @notebook = @element.find(".salvus-ipython-notebook-notebook")
        @con = @element.find(".salvus-ipython-notebook-connecting")
        @setup () =>
            # TODO: We have to do this stupid thing because in IPython's notebook.js they don't systematically use
            # set_dirty, sometimes instead just directly seting the flag.  So there's no simple way to know exactly
            # when the notebook is dirty. (TODO: fix all this via upstream patches.)
            # Also, note there are cases where IPython doesn't set the dirty flag
            # even though the output has changed.   For example, if you type "123" in a cell, run, then
            # comment out the line and shift-enter again, the empty output doesn't get sync'd out until you do
            # something else.  If any output appears then the dirty happens.  I guess this is a bug that should be fixed in ipython.
            @_autosync_interval = setInterval(@autosync, @opts.sync_interval)
            @_cursor_interval = setInterval(@broadcast_cursor_pos, @opts.cursor_interval)

    status: (text) =>
        if not text?
            text = ""
        else if false
            text += " (started at #{Math.round(misc.walltime(@_start_time))}s)"
        @status_element.html(text)

    setup: (cb) =>
        if @_setting_up
            cb?("already setting up")
            return  # already setting up
        @_setting_up = true
        @con.show().icon_spin(start:true)
        delete @_cursors   # Delete all the cached cursors in the DOM
        delete @nb
        delete @frame

        async.series([
            (cb) =>
                @status("determining newest ipynb file")
                salvus_client.exec
                    project_id : @editor.project_id
                    path       : @path
                    command    : "ls"
                    args       : ['-lt', "--time-style=+%s", @file, @syncdoc_filename]
                    timeout    : 10
                    err_on_exit: false
                    cb         : (err, output) =>
                        if err?
                            cb(err)
                        else if output.stderr.indexOf('No such file or directory') != -1
                            # nothing to do -- the syncdoc file doesn't even exist.
                            cb()
                        else
                            # figure out the two times and see if the .ipynb file is at least 10 seconds (say)
                            # newer than the syncdoc.
                            #~$ ls -l --time-style=+%s .2013-09-06-080011.ipynb.syncdoc 2013-09-06-080011.ipynb
                            #-rw-rw-r-- 1 ccnIX7aT ccnIX7aT 43560 1378514636 2013-09-06-080011.ipynb
                            #-rw-rw-r-- 1 ccnIX7aT ccnIX7aT 41821 1378513328 .2013-09-06-080011.ipynb.syncdoc
                            v = output.stdout.split('\n')
                            a = {}
                            a[v[0][6]] = parseInt(v[0][5])
                            a[v[1][6]] = parseInt(v[1][5])
                            if a[@file] >= a[@syncdoc_filename] + 10
                                @_use_disk_file = true
                            cb()
            (cb) =>
                @status("ensuring syncdoc exists")
                @editor.project_page.ensure_file_exists
                    path : @syncdoc_filename
                    cb   : cb
            (cb) =>
                @initialize(cb)
            (cb) =>
                @_init_doc(cb)
                @init_autosave()
        ], (err) =>
            @con.show().icon_spin(false).hide()
            @_setting_up = false
            if err
                @save_button.addClass("disabled")
                @status("failed to start -- #{err}")
                cb?("Unable to start IPython server -- #{err}")
            else
                cb?()
        )

    _init_doc: (cb) =>
        #console.log("_init_doc: connecting to sync session")
        @status("connecting to sync session")
        if @doc?
            # already initialized
            @doc.sync () =>
                @set_live_from_syncdoc()
                @iframe.animate(opacity:1)
                cb?()
            return
        @doc = syncdoc.synchronized_string
            project_id : @editor.project_id
            filename   : @syncdoc_filename
            sync_interval : @opts.sync_interval
            cb         : (err) =>
                #console.log("_init_doc returned: err=#{err}")
                @status()
                if err
                    cb?("Unable to connect to synchronized document server -- #{err}")
                else
                    if @_use_disk_file
                        @doc.live('')
                    @_config_doc()
                    cb?()

    _config_doc: () =>
        #console.log("_config_doc")
        # todo -- should check if .ipynb file is newer... ?
        @status("setting visible document to sync")
        if @doc.live() == ''
            @doc.live(@to_doc())
        else
            @set_live_from_syncdoc()
        #console.log("DONE SETTING!")
        @iframe.animate(opacity:1)

        @doc._presync = () =>
            if not @nb? or @_reloading
                # no point -- reinitializing the notebook frame right now...
                return
            @doc.live(@to_doc())

        apply_edits = @doc.dsync_client._apply_edits_to_live

        apply_edits2 = (patch, cb) =>
            #console.log("_apply_edits_to_live ")#-- #{JSON.stringify(patch)}")
            before =  @to_doc()
            if not before?
                cb?("reloading")
                return
            @doc.dsync_client.live = before
            apply_edits(patch)
            if @doc.dsync_client.live != before
                @from_doc(@doc.dsync_client.live)
                #console.log("edits should now be applied!")#, @doc.dsync_client.live)
            cb?()

        @doc.dsync_client._apply_edits_to_live = apply_edits2

        @doc.on "reconnect", () =>
            if not @doc.dsync_client?
                # this could be an older connect emit that didn't get handled -- ignore.
                return
            apply_edits = @doc.dsync_client._apply_edits_to_live
            @doc.dsync_client._apply_edits_to_live = apply_edits2
            # Update the live document with the edits that we missed when offline
            @status("reconnect - updating live doc with missed edits")
            @from_doc(@doc.dsync_client.live)
            @status()

        # TODO: we should just create a class that derives from SynchronizedString at this point.
        @doc.draw_other_cursor = (pos, color, name) =>
            if not @_cursors?
                @_cursors = {}
            id = color + name
            cursor_data = @_cursors[id]
            if not cursor_data?
                if not @frame?.$?
                    # do nothing in case initialization is incomplete
                    return
                cursor = templates.find(".salvus-editor-codemirror-cursor").clone().show()
                # craziness -- now move it into the iframe!
                cursor = @frame.$("<div>").html(cursor.html())
                cursor.css(position: 'absolute', width:'15em')
                inside = cursor.find(".salvus-editor-codemirror-cursor-inside")
                inside.css
                    'background-color': color
                    position : 'absolute'
                    top : '-1.3em'
                    left: '.5ex'
                    height : '1.15em'
                    width  : '.1ex'
                    'border-left': '2px solid black'
                    border  : '1px solid #aaa'
                    opacity :'.7'

                label = cursor.find(".salvus-editor-codemirror-cursor-label")
                label.css
                    color:'color'
                    position:'absolute'
                    top:'-2.3em'
                    left:'1.5ex'
                    'font-size':'8pt'
                    'font-family':'serif'
                    'z-index':10000
                label.text(name)
                cursor_data = {cursor: cursor, pos:pos}
                @_cursors[id] = cursor_data
            else
                cursor_data.pos = pos

            # first fade the label out
            cursor_data.cursor.find(".salvus-editor-codemirror-cursor-label").stop().show().animate(opacity:1).fadeOut(duration:16000)
            # Then fade the cursor out (a non-active cursor is a waste of space).
            cursor_data.cursor.stop().show().animate(opacity:1).fadeOut(duration:60000)
            @nb?.get_cell(pos.index)?.code_mirror.addWidget(
                      {line:pos.line,ch:pos.ch}, cursor_data.cursor[0], false)
        @status()


    broadcast_cursor_pos: () =>
        if not @nb?
            # no point -- reloading or loading
            return
        index = @nb.get_selected_index()
        cell  = @nb.get_cell(index)
        if not cell?
            return
        pos   = cell.code_mirror.getCursor()
        s = misc.to_json(pos)
        if s != @_last_cursor_pos
            @_last_cursor_pos = s
            @doc.broadcast_cursor_pos(index:index, line:pos.line, ch:pos.ch)

    remove: () =>
        if @_sync_check_interval?
            clearInterval(@_sync_check_interval)
        if @_cursor_interval?
            clearInterval(@_cursor_interval)
        if @_autosync_interval?
            clearInterval(@_autosync_interval)
        if @_reconnect_interval?
            clearInterval(@_reconnect_interval)
        @element.remove()
        @doc?.disconnect_from_session()
        @_dead = true

    get_ids: (cb) =>   # cb(err); if no error, sets @kernel_id and @notebook_id, though @kernel_id will be null if not started
        if not @server?
            cb("cannot call get_ids until connected to the ipython notebook server."); return
        @status("getting notebook and kernel id")
        @server.notebooks (err, notebooks) =>
            @status()
            if err
                cb(err); return
            for n in notebooks
                if n.name + '.ipynb' == @file
                    @kernel_id = n.kernel_id  # will be null if kernel not yet started
                    @notebook_id = n.notebook_id
                    cb(); return
            cb("no ipython notebook listed by server with name '#{@file}'")

    initialize: (cb) =>
        async.series([
            (cb) =>
                @status("getting or starting ipython server")
                ipython_notebook_server
                    project_id : @editor.project_id
                    path       : @path
                    cb         : (err, server) =>
                        @server = server
                        cb(err)
            (cb) =>
                @get_ids(cb)
            (cb) =>
                @_init_iframe(cb)
            (cb) =>
                # start polling until we get the kernel_id
                attempts = 0
                f = () =>
                    attempts += 1
                    if attempts < 20
                        @get_ids () =>
                            if not @kernel_id?
                                setTimeout(f,500)
                            else
                                cb()
                    else
                        cb("unable to get kernel id")
                setTimeout(f, 250)
        ], cb)

    # Initialize the embedded iframe and wait until the notebook object in it is initialized.
    # If this returns (calls cb) without an error, then the @nb attribute must be defined.
    _init_iframe: (cb) =>
        #console.log("* starting _init_iframe**")
        if not @notebook_id?
            # assumes @notebook_id has been set
            #console.log("exit _init_iframe 1")
            cb("must first call get_ids"); return

        @status("initializing iframe")
        get_with_retry
            url : @server.url
            cb  : (err) =>
                if err
                    @status()
                    #console.log("exit _init_iframe 2")
                    cb(err); return
                @iframe_uuid = misc.uuid()

                @status("loading iframe")

                @iframe = $("<iframe name=#{@iframe_uuid} id=#{@iframe_uuid}>").css('opacity','.01').attr('src', @server.url + @notebook_id)
                @notebook.html('').append(@iframe)
                @show()

                # Monkey patch the IPython html so clicking on the IPython logo pops up a new tab with the dashboard,
                # instead of messing up our embedded view.
                attempts = 0
                delay = 200
                start_time = misc.walltime()
                # What f does below is purely inside the browser DOM -- not the network, so doing it frequently is not a serious
                # problem for the server.
                f = () =>
                    #console.log("(attempt #{attempts}, time #{misc.walltime(start_time)}): @frame.ipython=#{@frame?.IPython?}, notebook = #{@frame?.IPython?.notebook?}, kernel= #{@frame?.IPython?.notebook?.kernel?}")
                    if @_dead?
                        cb("dead"); return
                    attempts += 1
                    if delay <= 750  # exponential backoff up to 300ms.
                        delay *= 1.2
                    if attempts >= 80
                        # give up after this much time.
                        msg = "failed to load IPython notebook"
                        @status(msg)
                        #console.log("exit _init_iframe 3")
                        cb(msg)
                        return
                    @frame = window.frames[@iframe_uuid]
                    if not @frame? or not @frame?.$? or not @frame.IPython? or not @frame.IPython.notebook? or not @frame.IPython.notebook.kernel?
                        setTimeout(f, delay)
                    else
                        a = @frame.$("#ipython_notebook").find("a")
                        if a.length == 0
                            setTimeout(f, delay)
                        else
                            @ipython = @frame.IPython
                            if not @ipython.notebook?
                                msg = "something went wrong -- notebook object not defined in IPython frame"
                                @status(msg)
                                #console.log("exit _init_iframe 4")
                                cb(msg)
                                return
                            @nb = @ipython.notebook

                            a.click () =>
                                @info()
                                return false

                            # Replace the IPython Notebook logo, which is for some weird reason an ugly png, with proper HTML; this ensures the size
                            # and color match everything else.
                            a.html('<span style="font-size: 18pt;"><span style="color:black">IP</span>[<span style="color:black">y</span>]: Notebook</span>')

                            # proper file rename with sync not supported yet (but will be -- TODO; needs to work with sync system)
                            @frame.$("#notebook_name").unbind('click').css("line-height",'0em')

                            # Get rid of file menu, which weirdly and wrongly for sync replicates everything.
                            for cmd in ['new', 'open', 'copy', 'rename']
                                @frame.$("#" + cmd + "_notebook").remove()
                            @frame.$("#kill_and_exit").remove()
                            @frame.$("#menus").find("li:first").find(".divider").remove()

                            @frame.$('<style type=text/css></style>').html(".container{width:98%; margin-left: 0;}").appendTo(@frame.$("body"))
                            @nb._save_checkpoint = @nb.save_checkpoint
                            @nb.save_checkpoint = @save

                            # Ipython doesn't consider a load (e.g., snapshot restore) "dirty" (for obvious reasons!)
                            @nb._load_notebook_success = @nb.load_notebook_success
                            @nb.load_notebook_success = (data,status,xhr) =>
                                @nb._load_notebook_success(data,status,xhr)
                                @sync()

                            # Periodically reconnect the IPython websocket.  This is LAME to have to do, but if I don't do this,
                            # then the thing hangs and reconnecting then doesn't work (the user has to do a full frame refresh).
                            # TODO: understand this and fix it properly.  This is entirely related to the complicated proxy server
                            # stuff in SMC, not sync!
                            websocket_reconnect = () =>
                                @nb?.kernel?.start_channels()
                            @_reconnect_interval = setInterval(websocket_reconnect, 15000)

                            @status()
                            cb()

                setTimeout(f, delay)

    # although highly unlikely, this could happen if something else steals our port before we can restart...
    check_for_moved_server: () =>
        if @nb?.kernel?  # only try if nb is already loaded
            if not @nb.kernel.shell_channel   # if backend is gone/replaced, then this would get set to null
                ipython_notebook_server
                    project_id : @editor.project_id
                    path       : @path
                    cb         : (err, server) =>
                        if err
                            # nothing to be done.
                            return
                        if server.url != @server.url
                            # server moved!?
                            @server = server
                            @reload() # -- only thing we can do, really

    autosync: () =>
        @check_for_moved_server()  # only bother if document being changed.
        if @frame?.IPython?.notebook?.dirty and not @_reloading
            #console.log("causing sync")
            @save_button.removeClass('disabled')
            @sync()
            @nb.dirty = false

    sync: () =>
        @save_button.icon_spin(start:true,delay:1000)
        @doc.sync () =>
            @save_button.icon_spin(false)

    has_unsaved_changes: () =>
        return not @save_button.hasClass('disabled')

    save: (cb) =>
        if not @nb?
            cb?(); return
        @save_button.icon_spin(start:true,delay:500)
        @nb._save_checkpoint?()
        @doc.save () =>
            @save_button.icon_spin(false)
            @save_button.addClass('disabled')
            cb?()

    set_live_from_syncdoc: () =>
        if not @doc?.dsync_client?  # could be re-initializing
            return
        current = @to_doc()
        if not current?
            return
        if @doc.dsync_client.live != current
            @from_doc(@doc.dsync_client.live)

    info: () =>
        t = "<h3>The IPython Notebook</h3>"
        t += "<h4>Enhanced with Sagemath Cloud Sync</h4>"
        t += "You are editing this document using the IPython Notebook enhanced with realtime synchronization."
        if @kernel_id?
            t += "<h4>Sage mode by pasting this into a cell</h4>"
            t += "<pre>%load_ext sage.misc.sage_extension</pre>"
        if @kernel_id?
            t += "<h4>Connect to this IPython kernel in a terminal</h4>"
            t += "<pre>ipython console --existing #{@kernel_id}</pre>"
        if @server.url?
            t += "<h4>Pure IPython notebooks</h4>"
            t += "You can also directly use an <a target='_blank' href='#{@server.url}'>unmodified version of the IPython Notebook server</a> (this link works for all project collaborators).  "
            t += "<br><br>To start your own unmodified IPython Notebook server that is securely accessible to collaborators, type in a terminal <br><br><pre>ipython-notebook run</pre>"
            t += "<h4>Known Issues</h4>"
            t += "If two people edit the same <i>cell</i> simultaneously, the cursor will jump to the start of the cell."
        bootbox.alert(t)
        return false

    reload: () =>
        if @_reloading
            return
        @_reloading = true
        @_cursors = {}
        @reload_button.find("i").addClass('fa-spin')
        @initialize (err) =>
            @_init_doc () =>
                @_reloading = false
                @status('')
                @reload_button.find("i").removeClass('fa-spin')

    init_buttons: () =>
        @element.find("a").tooltip()
        @save_button = @element.find("a[href=#save]").click () =>
            @save()
            return false

        @reload_button = @element.find("a[href=#reload]").click () =>
            @reload()
            return false

        #@element.find("a[href=#json]").click () =>
        #    console.log(@to_obj())

        @element.find("a[href=#info]").click () =>
            @info()
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

        @element.find("a[href=#execute]").click () =>
            @nb?.execute_selected_cell()
            return false
        @element.find("a[href=#interrupt]").click () =>
            @nb?.kernel.interrupt()
            return false
        @element.find("a[href=#tab]").click () =>
            @nb?.get_cell(@nb?.get_selected_index()).completer.startCompletion()
            return false

    # WARNING: Do not call this before @nb is defined!
    to_obj: () =>
        #console.log("to_obj: start"); t = misc.mswalltime()
        if not @nb?
            # can't get obj
            return undefined
        obj = @nb.toJSON()
        obj.metadata.name  = @nb.notebook_name
        obj.nbformat       = @nb.nbformat
        obj.nbformat_minor = @nb.nbformat_minor
        #console.log("to_obj: done", misc.mswalltime(t))
        return obj

    from_obj: (obj) =>
        #console.log("from_obj: start"); t = misc.mswalltime()
        if not @nb?
            return
        i = @nb.get_selected_index()
        st = @nb.element.scrollTop()
        @nb.fromJSON(obj)
        @nb.dirty = false
        @nb.select(i)
        @nb.element.scrollTop(st)
        #console.log("from_obj: done", misc.mswalltime(t))

    # Notebook Doc Format: line 0 is meta information in JSON; one line with the JSON of each cell for reset of file
    to_doc: () =>
        #console.log("to_doc: start"); t = misc.mswalltime()
        obj = @to_obj()
        if not obj?
            return
        doc = misc.to_json({notebook_name:obj.metadata.name})
        for cell in obj.worksheets[0].cells
            doc += '\n' + misc.to_json(cell)
        #console.log("to_doc: done", misc.mswalltime(t))
        return doc

    ###
    # simplistic version of modifying the notebook in place.  VERY slow when new cell added.
    from_doc0: (doc) =>
        #console.log("from_doc: start"); t = misc.mswalltime()
        nb = @nb
        v = doc.split('\n')
        nb.metadata.name  = v[0].notebook_name
        cells = []
        for line in v.slice(1)
            try
                c = misc.from_json(line)
                cells.push(c)
            catch e
                console.log("error de-jsoning '#{line}'", e)
        obj = @to_obj()
        obj.worksheets[0].cells = cells
        @from_obj(obj)
        console.log("from_doc: done", misc.mswalltime(t))
    ###

    delete_cell: (index) =>
        @nb?.delete_cell(index)

    insert_cell: (index, cell_data) =>
        if not @nb?
            return
        new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
        new_cell.fromJSON(cell_data)

    set_cell: (index, cell_data) =>
        #console.log("set_cell: start"); t = misc.mswalltime()
        if not @nb?
            return

        cell = @nb.get_cell(index)

        if cell? and cell_data.cell_type == cell.cell_type
            #console.log("setting in place")

            if cell.output_area?
                # for some reason fromJSON doesn't clear the output (it should, imho), and the clear_output method
                # on the output_area doesn't work as expected.
                wrapper = cell.output_area.wrapper
                wrapper.empty()
                cell.output_area = new @ipython.OutputArea(wrapper, true)

            cell.fromJSON(cell_data)

            ###  for debugging that we properly update a cell in place -- if this is wrong,
            #    all hell breaks loose, and sync loops ensue.
            a = misc.to_json(cell_data)
            b = misc.to_json(cell.toJSON())
            if a != b
                console.log("didn't work:")
                console.log(a)
                console.log(b)
                @nb.delete_cell(index)
                new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
                new_cell.fromJSON(cell_data)
            ###

        else
            #console.log("replacing")
            @nb.delete_cell(index)
            new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
            new_cell.fromJSON(cell_data)
        #console.log("set_cell: done", misc.mswalltime(t))

    ###
    # simplistic version of setting from doc; *very* slow on cell insert.
    from_doc0: (doc) =>
        console.log("goal='#{doc}'")
        console.log("live='#{@to_doc()}'")

        console.log("from_doc: start"); t = misc.mswalltime()
        goal = doc.split('\n')
        live = @to_doc().split('\n')

        @nb.metadata.name  = goal[0].notebook_name

        for i in [1...Math.max(goal.length, live.length)]
            index = i-1
            if i >= goal.length
                console.log("deleting cell #{index}")
                @nb.delete_cell(index)
            else if goal[i] != live[i]
                console.log("replacing cell #{index}")
                try
                    cell_data = JSON.parse(goal[i])
                    @set_cell(index, cell_data)
                catch e
                    console.log("error de-jsoning '#{goal[i]}'", e)

        console.log("from_doc: done", misc.mswalltime(t))
    ###

    from_doc: (doc) =>
        #console.log("goal='#{doc}'")
        #console.log("live='#{@to_doc()}'")
        #console.log("from_doc: start"); tm = misc.mswalltime()
        if not @nb?
            # The live notebook is not currently initialized -- there's nothing to be done for now.
            # This can happen if reconnect (to hub) happens at the same time that user is reloading
            # the ipython notebook frame itself.   The doc will get set properly at the end of the
            # reload anyways, so no need to set it here.
            return

        goal = doc.split('\n')
        live = @to_doc()?.split('\n')
        if not live?
            # reloading...
            return
        @nb.metadata.name  = goal[0].notebook_name

        v0    = live.slice(1)
        v1    = goal.slice(1)
        string_mapping = new misc.StringCharMapping()
        v0_string  = string_mapping.to_string(v0)
        v1_string  = string_mapping.to_string(v1)
        diff = diffsync.dmp.diff_main(v0_string, v1_string)

        index = 0
        i = 0

        parse = (s) ->
            try
                return JSON.parse(s)
            catch e
                console.log("UNABLE to parse '#{s}' -- not changing this cell.")

        #console.log("diff=#{misc.to_json(diff)}")
        i = 0
        while i < diff.length
            chunk = diff[i]
            op    = chunk[0]  # -1 = delete, 0 = leave unchanged, 1 = insert
            val   = chunk[1]
            if op == 0
                # skip over  cells
                index += val.length
            else if op == -1
                # delete  cells:
                # A common special case arises when one is editing a single cell, which gets represented
                # here as deleting then inserting.  Replacing is far more efficient than delete and add,
                # due to the overhead of creating codemirror instances (presumably).  (Also, there is a
                # chance to maintain the cursor later.)
                if i < diff.length - 1 and diff[i+1][0] == 1 and diff[i+1][1].length == val.length
                    #console.log("replace")
                    for x in diff[i+1][1]
                        obj = parse(string_mapping._to_string[x])
                        if obj?
                            @set_cell(index, obj)
                        index += 1
                    i += 1 # skip over next chunk
                else
                    #console.log("delete")
                    for j in [0...val.length]
                        @delete_cell(index)
            else if op == 1
                # insert new cells
                #console.log("insert")
                for x in val
                    obj = parse(string_mapping._to_string[x])
                    if obj?
                        @insert_cell(index, obj)
                    index += 1
            else
                console.log("BUG -- invalid diff!", diff)
            i += 1

        #console.log("from_doc: done", misc.mswalltime(tm))
        #if @to_doc() != doc
        #    console.log("FAIL!")
        #    console.log("goal='#{doc}'")
        #    console.log("live='#{@to_doc()}'")
        #    @from_doc0(doc)

    focus: () =>
        # TODO
        # console.log("ipython notebook focus: todo")

    show: () =>
        @element.show()
        top = @editor.editor_top_position()
        @element.css(top:top)
        if top == 0
            @element.css('position':'fixed')
        w = $(window).width()
        @iframe?.attr('width',w).maxheight()

#**************************************************
# other...
#**************************************************


class Spreadsheet extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        opts = @opts = defaults opts,{}
        @element = $("<div>Salvus spreadsheet not implemented yet.</div>")

class Slideshow extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        opts = @opts = defaults opts,{}
        @element = $("<div>Salvus slideshow not implemented yet.</div>")
