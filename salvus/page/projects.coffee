###################################################
#
# View and manipulate the list of user projects
#
###################################################

{salvus_client} = require('salvus_client')
{top_navbar}    = require('top_navbar')
{alert_message} = require('alerts')
misc            = require('misc')
{project_page}  = require('project')
{human_readable_size} = require('misc_page')
{account_settings} = require('account')

top_navbar.on "switch_to_page-projects", () ->
    window.history.pushState("", "", window.salvus_base_url + '/projects')
    update_project_list?()
    $(".projects-find-input").focus()


project_list = undefined
project_hashtags = {}
compute_search_data = () ->
    if project_list?
        project_hashtags = {}  # reset global variable
        for project in project_list
            project.search = (project.title+' '+project.description).toLowerCase()
            for k in misc.split(project.search)
                if k[0] == '#'
                    tag = k.slice(1).toLowerCase()
                    if not project_hashtags[tag]?
                        project_hashtags[tag] = []
                    project_hashtags[tag].push(project)

    # NOTE: create_project_item also adds to project.search, with info about the users of the projects

project_list_spinner = $("#projects").find(".projects-project-list-spinner")

update_project_list = exports.update_project_list = (cb) ->

    timer = setTimeout( (() -> project_list_spinner.show().spin()), 2500 )

    salvus_client.get_projects
        cb: (error, mesg) ->
            clearTimeout(timer); project_list_spinner.spin(false).hide()

            if not error and mesg.event == 'all_projects'
                project_list = mesg.projects
            else
                alert_message(type:"error", message:"Problem getting updated list of projects. #{error}. #{misc.to_json(mesg)}")

                #if salvus_client.account_id?
                #    x = localStorage[salvus_client.account_id + 'project_list']
                #    if x?
                #        console.log("loading project_list from cache")
                #        project_list = misc.from_json(x)

            if project_list?
                for p in project_list
                    if p.owner?
                        p.ownername = misc.make_valid_name(p.owner[0].first_name + p.owner[0].last_name)
                compute_search_data()
                update_project_view()

            cb?()

project_refresh_button = $("#projects").find("a[href=#refresh-projects]").click () ->
    project_refresh_button.addClass('fa-spin')
    update_project_list () ->
        project_refresh_button.removeClass('fa-spin')
    return false




# update caused by update happenin on some other client
salvus_client.on('project_list_updated', ((data) -> update_project_list()))

# search as you type
$(".projects-find-input").keyup (event) ->
    update_project_view()
    return false

$(".projects-search-form-input-clear").click () =>
    $(".projects-find-input").val('').focus()
    update_project_view()
    return false


# search when you click a button (which must be uncommented in projects.html):
#$(".projects-find-input").change((event) -> update_project_view())
#$(".projects").find(".form-search").find("button").click((event) -> update_project_view(); return false;)

select_filter_button = (which) ->
    for w in ['all', 'public', 'private', 'deleted']
        a = $("#projects-#{w}-button")
        if w == which
            a.removeClass("btn-info").addClass("btn-inverse")
        else
            a.removeClass("btn-inverse").addClass("btn-info")

only_public = false
only_private = false
only_deleted = false

$("#projects-all-button").click (event) ->
    only_public = false
    only_private = false
    only_deleted = false
    select_filter_button('all')
    update_project_view()

$("#projects-public-button").click (event) ->
    only_public = true
    only_private = false
    only_deleted = false
    select_filter_button('public')
    update_project_view()

$("#projects-private-button").click (event) ->
    only_public = false
    only_private = true
    only_deleted = false
    select_filter_button('private')
    update_project_view()

$("#projects-deleted-button").click (event) ->
    only_deleted = true
    only_private = false
    only_public = false
    select_filter_button('deleted')
    update_project_view()


DEFAULT_MAX_PROJECTS = 50

$("#projects-show_all").click( (event) -> update_project_view(true) )
template = $("#projects-project_list_item_template")

template_project_stored = $(".projects-location-states").find(".projects-location-restoring")
template_project_deploying = $(".projects-location-states").find(".projects-locatin-deploying")

create_project_item = (project) ->
    item = template.clone().show().data("project", project)

    if project.public
        item.find(".projects-public-icon").show()
        item.find(".projects-private-icon").hide()
        item.removeClass("private-project").addClass("public-project")
    else
        item.find(".projects-private-icon").show()
        item.find(".projects-public-icon").hide()
        item.addClass("private-project").removeClass("public-project")

    item.find(".projects-title").text(project.title)
    #if project.host != ""
    #    item.find(".projects-active").show().tooltip(title:"This project is opened, so you can access it quickly, search it, etc.", placement:"top", delay:500)

    item.find(".projects-last_edited").attr('title', (new Date(project.last_edited)).toISOString()).timeago()

    #if project.size?
    #    item.find(".projects-size").text(human_readable_size(project.size))

    item.find(".projects-description").text(project.description)

    users = []
    for group in misc.PROJECT_GROUPS
        if project[group]?
            for user in project[group]
                if user.account_id != salvus_client.account_id
                    users.push("#{user.first_name} #{user.last_name}") # (#{group})")  # use color for group...
                    project.search += (' ' + user.first_name + ' ' + user.last_name + ' ').toLowerCase()

    if users.length == 0
        u = ''
    else
        u = '  ' + users.join(', ')
    item.find(".projects-users-list").text(u)

    item.find(".projects-users").click () =>
        proj = open_project(project, item)
        proj.display_tab('project-settings')
        proj.container.find(".project-add-collaborator-input").focus()
        collab = proj.container.find(".project-collaborators-box")
        collab.css(border:'2px solid red')
        setTimeout((()->collab.css(border:'')), 5000)
        collab.css('box-shadow':'8px 8px 4px #888')
        setTimeout((()->collab.css('box-shadow':'')), 5000)
        return false

    if not project.location  # undefined or empty string
        item.find(".projects-location").append(template_project_stored.clone())
    else if project.location == "deploying"
        item.find(".projects-location").append(template_project_deploying.clone())

    item.click (event) ->
        open_project(project, item)
        return false


    return item

update_project_view = (show_all=false) ->
    if not project_list?
        return
    X = $("#projects-project_list")
    X.empty()
    # $("#projects-count").html(project_list.length)
    find_text = $(".projects-find-input").val().toLowerCase()
    n = 0

    desc = "Showing "
    if only_deleted
        desc += "deleted projects "
    else if only_public
        desc += "public projects "
    else if only_private
        desc += "private projects "
    else
        desc += "all projects "
    if find_text != ""
        desc += " whose title, description or users contain '#{find_text}'."

    $(".projects-describe-listing").text(desc)

    words = misc.split(find_text)
    match = (search) ->
        for word in words
            if search.indexOf(word) == -1
                return false
        return true

    for project in project_list
        if find_text != "" and not match(project.search)
            continue

        if only_public
            if not project.public
                continue

        if only_private
            if project.public
                continue

        if only_deleted
            if not project.deleted
                continue
        else
            if project.deleted
                continue

        n += 1
        if not show_all and n > DEFAULT_MAX_PROJECTS
            break
        create_project_item(project).appendTo(X)

    if n > DEFAULT_MAX_PROJECTS and not show_all
        $("#projects-show_all").show()
    else
        $("#projects-show_all").hide()

open_project = (project, item) ->
    #if not top_navbar.pages[project.project_id]? and top_navbar.number_of_pages_left() >= 5
    proj = project_page(project)
    top_navbar.switch_to_page(project.project_id)

    if not (project.location? and project.location != "deploying")
        alert_message
            type:"info"
            message:"Opening project #{project.title}... (this takes about 30 seconds)"
            timeout: 10
        if item?
            item.find(".projects-location").html("<i class='fa-spinner fa-spin'> </i>restoring...")
        salvus_client.project_info
            project_id : project.project_id
            cb         : (err, info) ->
                if err
                    alert_message(type:"error", message:"error opening project -- #{err}", timeout:6)
                    if item?
                        item.find(".projects-location").html("<i class='fa-bug'></i> (last open failed)")
                    return
                if not info.location?
                    if item?
                        item.find(".projects-location").html("(none)")
                else
                    project.location = location
                    if item?
                        item.find(".projects-location").text("")
    return proj


################################################
# Create a New Project
################################################
$("#new_project-button").click((event) -> create_project.modal('show'))

create_project = $("#projects-create_project")

close_create_project = () ->
    create_project.modal('hide').find('input').val('')
    $("#projects-create_project-public").attr("checked", true)
    $("#projects-create_project-private").attr("checked", false)
    #$("#projects-create_project-location").val('')

create_project.find(".close").click((event) -> close_create_project())

$("#projects-create_project-button-cancel").click((event) -> close_create_project())

create_project.on("shown", () -> $("#projects-create_project-title").focus())

new_project_button = $("#projects-create_project-button-create_project").click (event) ->
    title = $("#projects-create_project-title").val()
    if title == ""
        title = $("#projects-create_project-title").attr("placeholder")
    description = $("#projects-create_project-description").val()
    if description == ""
        description = $("#projects-create_project-description").attr("placeholder")

    new_project_button.icon_spin(start:true)
    alert_message(message:"Creating new project '#{title}'.  This takes about 30 seconds.", timeout:10)
    salvus_client.create_project
        title       : title
        description : description
        public      : $("#projects-create_project-public").is(":checked")
        cb : (error, mesg) ->
            new_project_button.icon_spin(false)
            if error
                alert_message(type:"error", message:"Unable to connect to server to create new project '#{title}'; please try again later.")
            else if mesg.event == "error"
                alert_message(type:"error", message:mesg.error)
            else
                update_project_list()
    close_create_project()
    return false



# Open something defined by a URL inside a project where
#
# target = project-id/
# target = ownername/projectname/
#                                files/....
#                                recent
#                                new
#                                log
#                                settings
#                                search
#
exports.load_target = load_target = (target) ->
    #console.log("projects -- load_target=#{target}")
    if not target or target.length == 0
        top_navbar.switch_to_page("projects")
        return
    segments = target.split('/')
    project = undefined
    update_project_list () ->
        if misc.is_valid_uuid_string(segments[0])
            t = segments.slice(1).join('/')
            for p in project_list
                if p.project_id == segments[0]
                    project = p
                    break
            if not project?
                # have to get from database.
                #console.log("loading project '#{segments[0]}' not implemented")
                # TODO: this will just work via database lookup on public projects...
                alert_message(type:"error", message:"You do not have access to the project with id #{segments[0]}.")
                return
        else
            t         = segments.slice(2).join('/')
            ownername = segments[0]
            name      = segments[1]
            for p in project_list
                if p.ownername == ownername and p.name == name
                    project = p
                    break
            if not project?
                # have to get from database.
                #console.log("loading project '#{owner}/#{projectname}' not implemented")
                # TODO: this will just work via database lookup on public projects...
                alert_message(type:"error", message:"You do not have access to the project '#{owner}/#{projectname}.")
                return

        open_project(project).load_target(t)


################################################
# Shutdown all projects button
################################################
#$("#projects").find("a[href=#close-all-projects]").click () ->
#    close_all_projects()
#    return false
#
#close_all_projects = () ->
#    salvus_client.get_projects
#        cb : (err, mesg) ->
#            if err or mesg.event != 'all_projects'
#                alert_message(type:"error", message:"Unable to get list of projects. #{error}. #{misc.to_json(mesg)}")
#            else
                # # TODO -- use async.parallel, etc.? to know when done, and refresh as we go.
                # for project in mesg.projects
                #     if project.host != ""
                #         close_project
                #             project_id : project.project_id
                #             title      : project.title
                #             show_success_alert : true
                #             cb : (err) ->
                #                 update_project_list()


################################################
# Download all projects button
################################################
