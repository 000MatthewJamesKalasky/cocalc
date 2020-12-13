#########################################################################
# This file is part of CoCalc: Copyright © 2020 Sagemath, Inc.
# License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
#########################################################################

## TODO: rewrite/refactor this in typescript and move to misc-page/

$ = window.$

{IS_MOBILE} = require('./feature')
misc        = require('smc-util/misc')
{dmp}       = require('smc-util/sync/editor/generic/util')
markdown    = require('./markdown')
theme       = require('smc-util/theme')
{QueryParams} = require('./misc/query-params')

get_inspect_dialog = (editor) ->
    dialog = $('''
    <div class="webapp-codemirror-introspect modal"
         data-backdrop="static" tabindex="-1" role="dialog" aria-hidden="true">
        <div class="modal-dialog" style="width:90%">
            <div class="modal-content">
                <div class="modal-header">
                    <button type="button" class="close" aria-hidden="true">
                        <span style="font-size:20pt;">×</span>
                    </button>
                    <h4><div class="webapp-codemirror-introspect-title"></div></h4>
                </div>

                <div class="webapp-codemirror-introspect-content-source-code cm-s-default">
                </div>
                <div class="webapp-codemirror-introspect-content-docstring cm-s-default">
                </div>


                <div class="modal-footer">
                    <button class="btn btn-close btn-default">Close</button>
                </div>
            </div>
        </div>
    </div>
    ''')
    dialog.modal()
    dialog.data('editor', editor)

    dialog.find("button").click () ->
        dialog.modal('hide')
        dialog.remove() # also removing, we no longer have any use for this element!

    # see http://stackoverflow.com/questions/8363802/bind-a-function-to-twitter-bootstrap-modal-close
    dialog.on 'hidden.bs.modal', () ->
        dialog.data('editor').focus?()
        dialog.data('editor', 0)

    return dialog


#############################################
# JQuery Plugins
#############################################
{required, defaults} = require('smc-util/misc')


####################################
# Codemirror Extensions
####################################

# We factor out this extension so it can be applied to CodeMirror's in iframes, e.g., Jupyter's.

exports.cm_define_diffApply_extension = require('./codemirror/extensions/diff-apply').cm_define_diffApply_extension


exports.define_codemirror_extensions = () ->
    require('./codemirror/extensions/latex-code-folding');
    require('./codemirror/extensions/unindent');
    require('./codemirror/extensions/tab-as-space');
    require('./codemirror/extensions/set-value-nojump');
    require('./codemirror/extensions/spellcheck-highlight');
    exports.cm_define_diffApply_extension(CodeMirror)

    # Apply a CodeMirror changeObj to this editing buffer.
    CodeMirror.defineExtension 'apply_changeObj', (changeObj) ->
        @replaceRange(changeObj.text, changeObj.from, changeObj.to)
        if changeObj.next?
            @apply_changeObj(changeObj.next)

    CodeMirror.defineExtension 'patchApply', (patch) ->
        ## OPTIMIZATION: this is a naive and inefficient way to turn
        ## a patch into a diff.  We should just directly rewrite
        ## the code below to work with patch.
        cur_value = @getValue()
        new_value = dmp.patch_apply(patch, cur_value)[0]
        diff = dmp.diff_main(cur_value, new_value)
        @diffApply(diff)

    # This is an improved rewrite of simple-hint.js from the CodeMirror3 distribution.
    # It is used only by sage worksheets and nothing else, hence will get deprecated.
    CodeMirror.defineExtension 'showCompletions', (opts) ->
        {from, to, completions, target, completions_size} = defaults opts,
            from             : required
            to               : required
            completions      : required
            target           : required
            completions_size : 20

        if completions.length == 0
            return

        start_cursor_pos = @getCursor()
        that = @
        insert = (str) ->
            pos = that.getCursor()
            from.line = pos.line
            to.line   = pos.line
            shift = pos.ch - start_cursor_pos.ch
            from.ch += shift
            to.ch   += shift
            that.replaceRange(str, from, to)

        if completions.length == 1
            # do not include target in appended completion if it has a '*'
            if target.indexOf('*') == -1
                insert(target + completions[0])
            else
                insert(completions[0])
            return

        sel = $("<select>").css('width','auto')
        complete = $("<div>").addClass("webapp-completions").append(sel)
        for c in completions
            # do not include target in appended completion if it has a '*'
            if target.indexOf('*') == -1
                sel.append($("<option>").text(target + c))
            else
                sel.append($("<option>").text(c))
        sel.find(":first").attr("selected", true)
        sel.attr("size", Math.min(completions_size, completions.length))
        pos = @cursorCoords(from)

        complete.css
            left : pos.left   + 'px'
            top  : pos.bottom + 'px'
        $("body").append(complete)
        # If we're at the edge of the screen, then we want the menu to appear on the left of the cursor.
        winW = window.innerWidth or Math.max(document.body.offsetWidth, document.documentElement.offsetWidth)
        if winW - pos.left < sel.attr("clientWidth")
            complete.css(left: (pos.left - sel.attr("clientWidth")) + "px")
        # Hide scrollbar
        if completions.length <= completions_size
            complete.css(width: (sel.attr("clientWidth") - 1) + "px")

        done = false

        close = () ->
            if done
                return
            done = true
            complete.remove()

        pick = () ->
            insert(sel.val())
            close()
            if not IS_MOBILE
                setTimeout((() -> that.focus()), 50)

        sel.blur(pick)
        sel.dblclick(pick)
        if not IS_MOBILE  # do not do this on mobile, since it makes it unusable!
            sel.click(pick)
        sel.keydown (event) ->
            code = event.keyCode
            switch code
                when 13 # enter
                    pick()
                    return false
                when 27
                    close()
                    that.focus()
                    return false
                else
                    if code != 38 and code != 40 and code != 33 and code != 34 and not CodeMirror.isModifierKey(event)
                        close()
                        that.focus()
                        # Pass to CodeMirror (e.g., backspace)
                        that.triggerOnKeyDown(event)
        sel.focus()
        return sel

    # This is used only by sage worksheets and nothing else, hence will get deprecated.
    CodeMirror.defineExtension 'showIntrospect', (opts) ->
        opts = defaults opts,
            from      : required
            content   : required
            type      : required   # 'docstring', 'source-code' -- FUTURE:
            target    : required
        if typeof(opts.content) != 'string'
            # If for some reason the content isn't a string (e.g., undefined or an object or something else),
            # convert it a string, which will display fine.
            opts.content = "#{JSON.stringify(opts.content)}"
        element = get_inspect_dialog(@)
        element.find(".webapp-codemirror-introspect-title").text(opts.target)
        element.show()
        if opts.type == 'source-code'
            elt = element.find(".webapp-codemirror-introspect-content-source-code")[0]
            if elt? # see https://github.com/sagemathinc/cocalc/issues/1993
                CodeMirror.runMode(opts.content, 'python', elt)
        else
            elt = element.find(".webapp-codemirror-introspect-content-docstring")[0]
            if elt?  # see https://github.com/sagemathinc/cocalc/issues/1993
                CodeMirror.runMode(opts.content, 'text/x-rst', elt)

    CodeMirror.defineExtension 'foldCodeSelectionAware', (mode) ->
        editor = @
        # The variable mode determines whether we are mode or unfolding *everything*
        # selected.  If mode='fold', mode everything; if mode='unfold', unfolding everything;
        # and if mode=undefined, not yet decided.  If undecided, it's decided on the first
        # thing that we would toggle, e.g., if the first fold point is unfolded, we make sure
        # everything is folded in all ranges, but if the first fold point is not folded, we then
        # make everything unfolded.
        for selection in editor.listSelections()
            {start_line, end_line} = cm_start_end(selection)
            for n in [start_line .. end_line]
                pos = CodeMirror.Pos(n)
                if mode?
                    editor.foldCode(pos, null, mode)
                else
                    # try to toggle and see if anything happens
                    is_folded = editor.isFolded(pos)
                    editor.foldCode(pos)
                    if editor.isFolded(pos) != is_folded
                        # this is a foldable line, and what did we do?  keep doing it.
                        mode = if editor.isFolded(pos) then "fold" else "unfold"

    # $.get '/static/codemirror-extra/data/latex-completions.txt', (data) ->
    data = require('raw-loader!codemirror-extra/data/latex-completions.txt')
    s = data.split('\n')
    tex_hint = (editor) ->
        cur   = editor.getCursor()
        token = editor.getTokenAt(cur)
        #console.log(token)
        t = token.string
        completions = (a for a in s when a.slice(0,t.length) == t)
        ans =
            list : completions,
            from : CodeMirror.Pos(cur.line, token.start)
            to   : CodeMirror.Pos(cur.line, token.end)
    CodeMirror.registerHelper("hint", "stex", tex_hint)


    CodeMirror.defineExtension 'get_edit_mode', (opts) ->
        opts = defaults opts, {}
        cm = @
        switch cm.getModeAt(cm.getCursor()).name
            when 'markdown'
                return 'md'
            when 'xml'
                return 'html'
            when 'mediawiki'
                return 'mediawiki'
            when 'stex'
                return 'tex'
            when 'python' # FUTURE how to tell it to return sage when in a sagews file?
                return 'python'
            when 'r'
                return 'r'
            when 'julia'
                return 'julia'
            when 'sagews'    # WARNING: this doesn't work
                return 'sage'
            else
                mode = cm.getOption('mode').name
                if mode.slice(0,3) == 'gfm'
                    return 'md'
                else if mode.slice(0,9) == 'htmlmixed'
                    return 'html'
                else if mode.indexOf('mediawiki') != -1
                    return 'mediawiki'
                else if mode.indexOf('rst') != -1
                    return 'rst'
                else if mode.indexOf('stex') != -1
                    return 'tex'
                if mode not in ['md', 'html', 'tex', 'rst', 'mediawiki', 'sagews', 'r']
                    return 'html'

    CodeMirror.defineExtension 'edit_selection', (opts) ->
        opts = defaults opts,
            cmd  : required
            args : undefined
            mode : undefined
            cb   : undefined  # called after done; if there is a dialog, this could be a while.
        cm = @
        default_mode = opts.mode
        if not default_mode?
            default_mode = cm.get_edit_mode()

        canonical_mode = (name) ->
            exports.sagews_canonical_mode(name, default_mode)

        args = opts.args
        cmd = opts.cmd

        #console.log("edit_selection '#{misc.to_json(opts)}', mode='#{default_mode}'")

        # FUTURE: will have to make this more sophisticated, so it can
        # deal with nesting, spans, etc.
        strip = (src, left, right) ->
            #console.log("strip:'#{src}','#{left}','#{right}'")
            left  = left.toLowerCase()
            right = right.toLowerCase()
            src0  = src.toLowerCase()
            i = src0.indexOf(left)
            if i != -1
                j = src0.lastIndexOf(right)
                if j != -1
                    #console.log('strip match')
                    opts.cb?()
                    return src.slice(0,i) + src.slice(i+left.length,j) + src.slice(j+right.length)

        selections = cm.listSelections()

        # TODO: can't be at top level because misc_page gets imported by
        # share server; fix will be moving these extension definitions
        # to their own module, when refactoring this file.
        buttonbar = require('./editors/editor-button-bar')
        EDIT_COMMANDS = buttonbar.commands
        FONT_FACES = buttonbar.FONT_FACES

        #selections.reverse()
        for selection in selections
            mode = canonical_mode(cm.getModeAt(selection.head).name)
            #console.log("edit_selection(mode='#{mode}'), selection=", selection)
            from = selection.from()
            to = selection.to()
            src = cm.getRange(from, to)
            start_line_beginning = from.ch == 0
            until_line_ending    = cm.getLine(to.line).length == to.ch

            mode1 = mode
            data_for_mode = EDIT_COMMANDS[mode1]
            if not data_for_mode?
                console.warn("mode '#{mode1}' is not defined!")
                opts.cb?()
                return
            how = data_for_mode[cmd]
            if not how?
                if mode1 in ['md', 'mediawiki', 'rst']
                    # html fallback for markdown
                    mode1 = 'html'
                else if mode1 == "python"
                    # Sage fallback in python mode. FUTURE: There should be a Sage mode.
                    mode1 = "sage"
                how = EDIT_COMMANDS[mode1][cmd]

            # trim whitespace
            i = 0
            j = src.length-1
            if how? and (if how.trim? then how.trim else true)
                while i < src.length and /\s/.test(src[i])
                    i += 1
                while j > 0 and /\s/.test(src[j])
                    j -= 1
            j += 1
            left_white  = src.slice(0,i)
            right_white = src.slice(j)
            src         = src.slice(i,j)
            src0        = src

            done = false

            # this is an abuse, but having external links to the documentation is good
            if how?.url?
                exports.open_new_tab(how.url)
                done = true

            if how?.wrap?
                space = how.wrap.space
                left  = how.wrap.left  ? ""
                right = how.wrap.right ? ""
                process = (src) ->
                    if how.strip?
                        # Strip out any tags/wrapping from conflicting modes.
                        for c in how.strip
                            wrap = EDIT_COMMANDS[mode1][c].wrap
                            if wrap?
                                src1 = strip(src, wrap.left ? '', wrap.right ? '')
                                if src1?
                                    src = src1
                                    if space and src[0] == ' '
                                        src = src.slice(1)

                    src1  = strip(src, left, right)
                    if src1
                        # strip the wrapping
                        src = src1
                        if space and src[0] == ' '
                            src = src.slice(1)
                    else
                        # do the wrapping
                        src = "#{left}#{if space then ' ' else ''}#{src}#{right}"
                    return src

                if how.wrap.multi
                    src = (process(x) for x in src.split('\n')).join('\n')
                else
                    src = process(src)
                if how.wrap.newline
                    src = '\n' + src + '\n'
                    if not start_line_beginning
                        src = '\n' + src
                    if not until_line_ending
                        src += '\n'
                done = true

            if how?.insert? # to insert the code snippet right below, next line
                # SMELL: no idea what the strip(...) above is actually doing
                # no additional newline, if nothing is selected and at start of line
                if selection.empty() and from.ch == 0
                    src = how.insert
                else
                    # this also inserts a new line, if cursor is inside/end of line
                    src = "#{src}\n#{how.insert}"
                done = true

            switch cmd
                when 'link'
                    cm.insert_link(cb:opts.cb)
                    return
                when 'image'
                    cm.insert_image(cb:opts.cb)
                    return
                when 'SpecialChar'
                    cm.insert_special_char(cb:opts.cb)
                    return
                when 'font_size'
                    if mode in ['html', 'md', 'mediawiki']
                        for i in [1..7]
                            src1 = strip(src, "<font size=#{i}>", '</font>')
                            if src1
                                src = src1
                        if args != '3'
                            src = "<font size=#{args}>#{src}</font>"
                        done = true
                    else if mode == 'tex'
                        # we need 6 latex sizes, for size 1 to 7 (default 3, at index 2)
                        latex_sizes = ['tiny', 'footnotesize', 'normalsize', 'large', 'LARGE', 'huge', 'Huge']
                        i = parseInt(args)
                        if i in [1..7]
                            size = latex_sizes[i - 1]
                            src = "{\\#{size} #{src}}"
                        done = true

                when 'font_size_new'
                    if mode in ['html', 'md', 'mediawiki']
                        src0 = src.toLowerCase().trim()
                        if misc.startswith(src0, "<span style='font-size")
                            i = src.indexOf('>')
                            j = src.lastIndexOf('<')
                            src = src.slice(i+1,j)
                        if args != 'medium'
                            src = "<span style='font-size:#{args}'>#{src}</span>"
                        done = true
                    else if mode == 'tex'
                        # we need 6 latex sizes, for size 1 to 7 (default 3, at index 2)
                        latex_sizes = ['tiny', 'footnotesize', 'normalsize', 'large', 'LARGE', 'huge', 'Huge']
                        i = parseInt(args)
                        if i in [1..7]
                            size = latex_sizes[i - 1]
                            src = "{\\#{size} #{src}}"
                        done = true

                when 'color'
                    if mode in ['html', 'md', 'mediawiki']
                        src0 = src.toLowerCase().trim()
                        if misc.startswith(src0, "<span style='color")
                            i = src.indexOf('>')
                            j = src.lastIndexOf('<')
                            src = src.slice(i+1,j)
                        src = "<span style='color:#{args}'>#{src}</span>"
                        done = true

                when 'background-color'
                    if mode in ['html', 'md', 'mediawiki']
                        src0 = src.toLowerCase().trim()
                        if misc.startswith(src0, "<span style='background")
                            i = src.indexOf('>')
                            j = src.lastIndexOf('<')
                            src = src.slice(i+1,j)
                        src = "<span style='background-color:#{args}'>#{src}</span>"
                        done = true

                when 'font_face'  # old -- still used in some old non-react editors
                    if mode in ['html', 'md', 'mediawiki']
                        for face in FONT_FACES
                            src1 = strip(src, "<font face='#{face}'>", '</font>')
                            if src1
                                src = src1
                        src = "<font face='#{args}'>#{src}</font>"
                        done = true

                when 'font_family'  # new -- html5 style
                    if mode in ['html', 'md', 'mediawiki']
                        src0 = src.toLowerCase().trim()
                        if misc.startswith(src0, "<span style='font-family")
                            i = src.indexOf('>')
                            j = src.lastIndexOf('<')
                            src = src.slice(i+1,j)
                        if not src
                            src = '    '
                        src = "<span style='font-family:#{args}'>#{src}</span>"
                        done = true

                when 'clean'
                    if mode == 'html'
                        src = html_beautify($("<div>").html(src).html())
                        done = true

                when 'unformat'
                    if mode == 'html'
                        src = $("<div>").html(src).text()
                        done = true
                    else if mode == 'md'
                        src = $("<div>").html(markdown.markdown_to_html(src)).text()
                        done = true

            if not done?
                if DEBUG and not how?
                    console.warn("CodeMirror/edit_selection: unknown for mode1='#{mode1}' and cmd='#{cmd}'")

                #console.log("not implemented")
                opts.cb?()
                return "not implemented"

            if src == src0
                continue

            cm.focus()
            cm.replaceRange(left_white + src + right_white, from, to)

            if not how?.insert? and not how?.wrap?
                if selection.empty()
                    # restore cursor
                    if left?
                        delta = left.length
                    else
                        delta = 0
                    cm.setCursor({line:from.line, ch:to.ch+delta})
                else
                    # now select the new range
                    delta = src.length - src0.length
                    cm.extendSelection(from, {line:to.line, ch:to.ch+delta})
            opts.cb?()


    CodeMirror.defineExtension 'insert_link', (opts={}) ->
        opts = defaults opts,
            cb : undefined
        cm = @
        dialog = $("#webapp-editor-templates").find(".webapp-html-editor-link-dialog").clone()
        dialog.modal('show')
        dialog.find(".btn-close").off('click').click () ->
            dialog.modal('hide')
            setTimeout(focus, 50)
            return false
        url = dialog.find(".webapp-html-editor-url")
        url.focus()
        display = dialog.find(".webapp-html-editor-display")
        target  = dialog.find(".webapp-html-editor-target")
        title   = dialog.find(".webapp-html-editor-title")

        selected_text = cm.getSelection()
        display.val(selected_text)

        mode = cm.get_edit_mode()

        if mode in ['md', 'rst', 'tex']
            dialog.find(".webapp-html-editor-target-row").hide()

        submit = () =>
            dialog.modal('hide')
            if mode == 'md'
                # [Python](http://www.python.org/)
                title  = title.val()

                if title.length > 0
                    title = " \"#{title}\""

                d = display.val()
                if d.length > 0
                    s = "[#{d}](#{url.val()}#{title})"
                else
                    s = url.val()

            else if mode == "rst"
                # `Python <http://www.python.org/#target>`_

                if display.val().length > 0
                    display = "#{display.val()}"
                else
                    display = "#{url.val()}"

                s = "`#{display} <#{url.val()}>`_"

            else if mode == "tex"
                # \url{http://www.wikibooks.org}
                # \href{http://www.wikibooks.org}{Wikibooks home}
                cm.tex_ensure_preamble?("\\usepackage{url}")
                display = display.val().trim()
                url = url.val()
                url = url.replace(/#/g, "\\\#")  # should end up as \#
                url = url.replace(/&/g, "\\&")   # ... \&
                url = url.replace(/_/g, "\\_")   # ... \_
                if display.length > 0
                    s = "\\href{#{url}}{#{display}}"
                else
                    s = "\\url{#{url}}"

            else if mode == "mediawiki"
                # https://www.mediawiki.org/wiki/Help:Links
                # [http://mediawiki.org MediaWiki]
                display = display.val().trim()
                if display.length > 0
                    display = " #{display}"
                s = "[#{url.val()}#{display}]"

            else   # if mode == "html"  ## HTML default fallback
                target = target.val().trim()
                title  = title.val().trim()

                if target == "_blank"
                    target = " target='_blank' rel='noopener'"

                if title.length > 0
                    title = " title='#{title}'"

                if display.val().length > 0
                    display = "#{display.val()}"
                else
                    display = url.val()
                s = "<a href='#{url.val()}'#{title}#{target}>#{display}</a>"

            selections = cm.listSelections()
            selections.reverse()
            for sel in selections
                if sel.empty()
                    #console.log(cm, s, sel.head)
                    cm.replaceRange(s, sel.head)
                else
                    cm.replaceRange(s, sel.from(), sel.to())
            opts.cb?()

        dialog.find(".btn-submit").off('click').click(submit)
        dialog.keydown (evt) =>
            if evt.which == 13 # enter
                submit()
                return false
            if evt.which == 27 # escape
                dialog.modal('hide')
                opts.cb?()
                return false



    CodeMirror.defineExtension 'tex_ensure_preamble', (code) ->
        cm = @
        # ensures that the given line is the pre-amble of the latex document.
        # FUTURE: actually implement this!

        # in latex document do one thing

        # in sagews will do something to %latex.

    CodeMirror.defineExtension 'insert_image', (opts={}) ->
        opts = defaults opts,
            cb : undefined
        cm = @

        dialog = $("#webapp-editor-templates").find(".webapp-html-editor-image-dialog").clone()
        dialog.modal('show')
        dialog.find(".btn-close").off('click').click () ->
            dialog.modal('hide')
            return false
        url = dialog.find(".webapp-html-editor-url")
        url.focus()

        mode = cm.get_edit_mode()

        if mode == "tex"
            # different units and don't let user specify the height
            dialog.find(".webapp-html-editor-height-row").hide()
            dialog.find(".webapp-html-editor-image-width-header-tex").show()
            dialog.find(".webapp-html-editor-image-width-header-default").hide()
            dialog.find(".webapp-html-editor-width").val('80')

        submit = () =>
            dialog.modal('hide')
            title  = dialog.find(".webapp-html-editor-title").val().trim()
            height = width = ''
            h = dialog.find(".webapp-html-editor-height").val().trim()
            if h.length > 0
                height = " height=#{h}"
            w = dialog.find(".webapp-html-editor-width").val().trim()
            if w.length > 0
                width = " width=#{w}"

            if mode == 'rst'
                # .. image:: picture.jpeg
                #    :height: 100px
                #    :width: 200 px
                #    :alt: alternate text
                #    :align: right
                s = "\n.. image:: #{url.val()}\n"
                height = dialog.find(".webapp-html-editor-height").val().trim()
                if height.length > 0
                    s += "   :height: #{height}px\n"
                width = dialog.find(".webapp-html-editor-width").val().trim()
                if width.length > 0
                    s += "   :width: #{width}px\n"
                if title.length > 0
                    s += "   :alt: #{title}\n"

            else if mode == 'md' and width.length == 0 and height.length == 0
                # use markdown's funny image format if width/height not given
                if title.length > 0
                    title = " \"#{title}\""
                s = "![](#{url.val()}#{title})"

            else if mode == "tex"
                cm.tex_ensure_preamble("\\usepackage{graphicx}")
                width = parseInt(dialog.find(".webapp-html-editor-width").val(), 10)
                if "#{width}" == "NaN"
                    width = "0.8"
                else
                    width = "#{width/100.0}"
                if title.length > 0
                    s = """
                        \\begin{figure}[p]
                            \\centering
                            \\includegraphics[width=#{width}\\textwidth]{#{url.val()}}
                            \\caption{#{title}}
                        \\end{figure}
                        """
                else
                    s = "\\includegraphics[width=#{width}\\textwidth]{#{url.val()}}"

            else if mode == "mediawiki"
                # https://www.mediawiki.org/wiki/Help:Images
                # [[File:Example.jpg|<width>[x<height>]px]]
                size = ""
                if w.length > 0
                    size = "|#{w}"
                    if h.length > 0
                        size += "x#{h}"
                    size += "px"
                s = "[[File:#{url.val()}#{size}]]"

            else # fallback for mode == "md" but height or width is given
                if title.length > 0
                    title = " title='#{title}'"
                s = "<img src='#{url.val()}'#{width}#{height}#{title}>"
            selections = cm.listSelections()
            selections.reverse()
            for sel in selections
                cm.replaceRange(s, sel.head)
            opts.cb?()

        dialog.find(".btn-submit").off('click').click(submit)
        dialog.keydown (evt) =>
            if evt.which == 13 # enter
                submit()
                return false
            if evt.which == 27 # escape
                dialog.modal('hide')
                opts.cb?()
                return false

    CodeMirror.defineExtension 'insert_special_char', (opts={}) ->
        opts = defaults opts,
            cb : undefined
        cm = @

        mode = cm.get_edit_mode()
        if mode not in ['html', 'md']
            bootbox.alert("<h3>Not Implemented</h3><br>#{mode} special symbols not yet implemented")
            return

        dialog = $("#webapp-editor-templates").find(".webapp-html-editor-symbols-dialog").clone()
        dialog.modal('show')
        dialog.find(".btn-close").off('click').click () ->
            dialog.modal('hide')
            return false


        selected = (evt) =>
            target = $(evt.target)
            if target.prop("tagName") != "SPAN"
                return
            dialog.modal('hide')
            code = target.attr("title")
            s = "&#{code};"
            # FUTURE: HTML-based formats will work, but not LaTeX.
            # As long as the input encoding in LaTeX is utf8, just insert the actual utf8 character (target.text())

            selections = cm.listSelections()
            selections.reverse()
            for sel in selections
                cm.replaceRange(s, sel.head)
            opts.cb?()

        dialog.find(".webapp-html-editor-symbols-dialog-table").off("click").click(selected)
        dialog.keydown (evt) =>
            if evt.which == 13 # enter
                submit()
                return false
            if evt.which == 27 # escape
                dialog.modal('hide')
                opts.cb?()
                return false

    # Find pos {line:line, ch:ch} of first line that contains the
    # string s, or returns undefined if no single line contains s.
    # Should be much faster than calling getLine or getValue.
    CodeMirror.defineExtension 'find_in_line', (s) ->
        line = undefined
        ch   = undefined
        i = 0
        @eachLine (z) ->
            ch = z.text.indexOf(s)
            if ch != -1
                line = i
                return true  # undocumented - calling false stops iteration
            i += 1
            return false
        if line?
            return {line:line, ch:ch}

    # Format the selected block (or blocks) of text, so it looks like this:
    #    stuff  : 'abc'
    #    foo    : 1
    #    more_0 : 'blah'
    # Or
    #    stuff  = 'abc'
    #    foo    = 1
    #    more_0 = 'blah'
    # The column separate is the first occurence in the first line of
    # one of '=' or ':'.  Selected lines that don't contain either symbol
    # are ignored.
    CodeMirror.defineExtension 'align_assignments', () ->
        for sel in @listSelections()
            {start_line, end_line} = cm_start_end(sel)
            symbol = undefined
            column = 0
            # first pass -- figure out what the symbol is and what column we will move it to.
            for n in [start_line .. end_line]
                x = @getLine(n)
                if not symbol?
                    # we still don't know what the separate symbol is.
                    if ':' in x
                        symbol = ':'
                    else if '=' in x
                        symbol = '='
                i = x.indexOf(symbol)
                if i == -1
                    continue   # no symbol in this line, so skip
                # reduce i until x[i-1] is NOT whitespace.
                while i > 0 and x[i-1].trim() == ''
                    i -= 1
                i += 1
                column = Math.max(i, column)
            if not symbol? or not column
                continue  # no symbol in this selection, or no need to move it.  Done.
            # second pass -- move symbol over by inserting space
            for n in [start_line .. end_line]
                x = @getLine(n)
                i = x.indexOf(symbol)
                if i != -1
                    # There is a symbol in this line -- put it in the spot where we want it.
                    if i < column
                        # symbol is too early -- add space
                        spaces = (' ' for j in [0...(column-i)]).join('')  # column - i spaces
                        # insert spaces in front of the symbol
                        @replaceRange(spaces, {line:n, ch:i}, {line:n, ch:i})
                    else if i > column
                        # symbol is too late -- remove spaces
                        @replaceRange('', {line:n, ch:column}, {line:n, ch:i})
                    # Ensure the right amount of whitespace after the symbol -- exactly one space
                    j = i + 1  # this will be the next position after x[i] that is not whitespace
                    while j < x.length and x[j].trim() == ''
                        j += 1
                    if j - i >= 2
                        # remove some spaces
                        @replaceRange('', {line:n, ch:column+1}, {line:n, ch:column+(j-i-1)})
                    else if j - i == 1
                        # insert a space
                        @replaceRange(' ', {line:n, ch:column+1}, {line:n, ch:column+1})





    # Natural analogue of getLine, which codemirror doesn't have for some reason
    #CodeMirror.defineExtension 'setLine', (n, value) ->
    #    @replaceRange()

cm_start_end = require('./codemirror/extensions/util').cm_start_end;

exports.download_file = (url) ->
    #console.log("download_file(#{url})")
    ## NOTE: the file has to be served with
    ##    res.setHeader('Content-disposition', 'attachment')
    iframe = $("<iframe>").addClass('hide').attr('src', url).appendTo($("body"))
    setTimeout((() -> iframe.remove()), 60000)

# Get the DOM node that the currently selected text starts at, as a jquery wrapped object;
# if the selection is a caret (hence empty) returns empty object
exports.get_selection_start_node = () ->
    node = undefined
    selection = undefined
    if window.getSelection # FF3.6, Safari4, Chrome5, IE11 (DOM Standards)
        selection = getSelection()
        if selection.isCollapsed
            return $()
        node = selection.anchorNode
    if not node and document.selection # old IE
        selection = document.selection
        range = (if selection.getRangeAt then selection.getRangeAt(0) else selection.createRange())
        node = (if range.commonAncestorContainer then range.commonAncestorContainer else (if range.parentElement then range.parentElement() else range.item(0)))
    if node
        $(if node.nodeName is "#text" then node.parentNode else node)
    else
        $()

# return true if d is a valid string -- see http://stackoverflow.com/questions/1353684/detecting-an-invalid-date-date-instance-in-javascript
exports.is_valid_date = (d) ->
    if Object::toString.call(d) isnt "[object Date]"
        return false
    else
        return not isNaN(d.getTime())

# Bootstrap 3 modal fix
$("html").on "hide.bs.modal", "body > .modal", (e) ->
    $(@).remove()
    return

# Bootstrap 3 tooltip fix
$("body").on "show.bs.tooltip", (e) ->
    setTimeout ( ->
        $(e.target).parent().find(".tooltip").tooltip "hide"
    ), 3000

exports.load_coffeescript_compiler = (cb) ->
    if CoffeeScript?
        cb?()
    else
        require.ensure [], =>
            # this should define window.CoffeeScript as the compiler instance.
            require("script-loader!coffeescript/lib/coffeescript/index.js")
            console.log("loaded CoffeeScript via require.ensure")
            cb?()

# Convert html to text safely using jQuery (see http://api.jquery.com/jquery.parsehtml/)

exports.html_to_text = require('./misc-page').html_to_text

exports.language = () ->
    (if navigator?.languages then navigator?.languages[0] else (navigator?.language or navigator?.userLanguage))


# get the currently selected html
exports.save_selection = () ->
    if window.getSelection
        sel = window.getSelection()
        if sel.getRangeAt and sel.rangeCount
            range = sel.getRangeAt(0)
    else if document.selection
        range = document.selection.createRange()
    return range

exports.restore_selection = (selected_range) ->
    if window.getSelection || document.createRange
        selection = window.getSelection()
        if selected_range
            try
                selection.removeAllRanges()
            catch ex
                document.body.createTextRange().select()
                document.selection.empty()
            selection.addRange(selected_range)
    else if document.selection and selected_range
        selected_range.select()


# this HTML sanitization is necessary in such a case, where the user enters
# arbitrary HTML and then this HTML is added to the DOM. For example, a loose
# open tag can cause the entire smc page to "crash", when it is inserted via
# a chat message and show in the chat box as a message.
# There are various tools available to do this, e.g.
# * https://www.npmjs.com/package/sanitize-html (which depends on other utilitis, might be handy?)
# * https://www.npmjs.com/package/sanitize or *-caja (from google, more standalone)
# * https://www.npmjs.com/package/google-caja-sanitizer (only the google thing)
# * another option: using <jQuery object>.html("<html>").html()
#
# in any case, almost all tags should be allowed here, no need to be too strict.
#
# FUTURE: the ones based on google-caja-sanitizer seem to have a smaller footprint,
# but I (hsy) wasn't able to configure them in such a way that all tags/attributes are allowed.
# It seems like there is some bug in the library, because the definitions to allow e.g. src in img are there.

exports.sanitize_html = (html) ->
    return jQuery("<div>").html(html).html()

# http://api.jquery.com/jQuery.parseHTML/ (expanded behavior in version 3+)
exports.sanitize_html = (html, keepScripts = true, keepUnsafeAttributes = true, post_hook = undefined) ->
    {sanitize_html_attributes} = require('smc-util/misc')
    sani = jQuery(jQuery.parseHTML('<div>' + html + '</div>', null, keepScripts))
    if not keepUnsafeAttributes
        sani.find('*').each ->
            sanitize_html_attributes(jQuery, this)
    if post_hook?
        post_hook(sani)
    return sani.html()

exports.sanitize_html_safe = (html, post_hook=undefined) ->
    exports.sanitize_html(html, false, false, post_hook)

###
_sanitize_html_lib = require('sanitize-html')

_sanitize_html_allowedTags = [ 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'p', 'a', 'ul', 'ol',
  'nl', 'li', 'b', 'i', 'strong', 'em', 'strike', 'code', 'hr', 'br', 'div',
  'img', 'br', 'hr', 'section', 'code', 'input', "strong",
  'table', 'thead', 'caption', 'tbody', 'tfoot', 'tr', 'th', 'td', 'pre' ]

_sanitize_html_allowedAttributes =
    a: [ 'href', 'name', 'target', 'style' ]
    img: [ 'src', 'style' ]
    '*': [ 'href', 'align', 'alt', 'center', 'bgcolor', 'style' ]

return _sanitize_html_lib html,
        allowedTags: _sanitize_html_allowedTags
        allowedAttributes: _sanitize_html_allowedAttributes
###


# conversion tracking (commercial only)
exports.track_conversion = (type, amount) ->
    return if not require('./customize').commercial
    return if DEBUG

    theme = require('smc-util/theme')
    if type == 'create_account'
        tag = theme.sign_up_id
        amount = 1 # that's not true
    else if type == 'subscription'
        tag = theme.conversion_id
    else
        console.warn("unknown conversion type: #{type}")
        return

    window.gtag?('event', 'conversion',
        send_to     : "#{theme.gtag_id}/#{tag}"
        value       : amount
        currency    : 'USD'
    )


# These are used to disable pointer events for iframes when dragging something that may move over an iframe.
# See http://stackoverflow.com/questions/3627217/jquery-draggable-and-resizeable-over-iframes-solution
exports.drag_start_iframe_disable = ->
    $("iframe:visible").css('pointer-events', 'none')

exports.drag_stop_iframe_enable = ->
    $("iframe:visible").css('pointer-events', 'auto')

# for backward compatibility, and no circular import
exports.open_popup_window = (args...) ->
    require('./misc-page/open-browser-tab').open_popup_window(args...)
exports.open_new_tab = (args...) ->
    require('./misc-page/open-browser-tab').open_new_tab(args...)


exports.get_cookie = (name) ->
    value = "; " + document.cookie
    parts = value.split("; " + name + "=")
    return parts.pop().split(";").shift() if (parts.length == 2)

exports.delete_cookie = (name) ->
    document.cookie = name + '=; expires=Thu, 01 Jan 1970 00:00:01 GMT; path=/'

exports.set_cookie = (name, value, days) ->
    expires = ''
    if days
        date = new Date()
        date.setTime(date.getTime() + (days*24*60*60*1000))
        expires = "; expires=" + date.toUTCString()
    document.cookie = name + "=" + value + expires + "; path=/"

# returns true, if a target page should be loaded
exports.should_load_target_url = ->
    return window.cocalc_target \
        and window.cocalc_target != 'login' \
        and not QueryParams.get('test')
