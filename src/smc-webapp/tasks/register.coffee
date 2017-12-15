###
Register the task list editor

TODO: this is very similar to jupyter/register.coffee -- can this be refactored?
###

misc                   = require('smc-util/misc')

{register_file_editor} = require('../file-editors')
{alert_message}        = require('../alerts')
{redux_name}           = require('../smc-react')
{webapp_client}        = require('../webapp_client')

{TaskList}             = require('./task-list')
{TaskActions}          = require('./actions')
{TaskStore}            = require('./store')

exports.register = ->
    register_file_editor
        ext       : ['tasks2']   # temporary extension JUST for development

        is_public : false

        icon      : 'tasks'

        component : TaskList

        init      : (path, redux, project_id) ->
            name = redux_name(project_id, path)
            if redux.getActions(name)?
                return name  # already initialized

            actions = redux.createActions(name, TaskActions)
            store   = redux.createStore(name, TaskStore)

            syncdb = webapp_client.sync_db
                project_id      : project_id
                path            : path
                primary_keys    : ['task_id']
                string_cols     : ['desc']
                change_throttle : 500
                save_interval   : 3000

            actions._init(project_id, path, syncdb, store, webapp_client)

            if window.smc?
                window.a = actions # for DEBUGGING

            syncdb.once 'init', (err) =>
                if err
                    mesg = "Error opening '#{path}' -- #{err}"
                    console.warn(mesg)
                    alert_message(type:"error", message:mesg)
                    return

            return name

        remove    : (path, redux, project_id) ->
            name = redux_name(project_id, path)
            actions = redux.getActions(name)
            actions?.close()
            store = redux.getStore(name)
            if not store?
                return
            delete store.state
            redux.removeStore(name)
            redux.removeActions(name)
            return name

        save      : (path, redux, project_id) ->
            name = redux_name(project_id, path)
            actions = redux.getActions(name)
            actions?.save()

exports.register()
