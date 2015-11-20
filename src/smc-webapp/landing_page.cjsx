{rclass, FluxComponent, React, ReactDOM, flux, rtypes} = require('./r')
{Alert, Button, ButtonToolbar, Col, Modal, Row, Input, Well} = require('react-bootstrap')
{ErrorDisplay, Icon, Loading, ImmutablePureRenderMixin, UNIT, SAGE_LOGO_COLOR, BS_BLUE} = require('./r_misc')
{HelpEmailLink, SiteName, SiteDescription} = require('./customize')

misc = require('smc-util/misc')

images = ['static/sagepreview/01-worksheet.png', 'static/sagepreview/02-courses.png', 'static/sagepreview/03-latex.png', 'static/sagepreview/05-sky_is_the_limit.png' ]
# 'static/sagepreview/04-files.png'

$.get window.smc_base_url + "/auth/strategies", (obj, status) ->
    if status == 'success'
        flux.getActions('account').setTo(strategies : obj)

$.get window.smc_base_url + "/registration", (obj, status) ->
    if status == 'success'
        flux.getActions('account').setTo(token : obj.token)

reset_password_key = () ->
    url_args = window.location.href.split("#")
    if url_args.length == 2 and url_args[1].slice(0, 6) == 'forgot'
        return url_args[1].slice(7, 7+36)
    return undefined

Passports = rclass
    displayName : 'Passports'

    propTypes :
        strategies : rtypes.array
        actions    : rtypes.object.isRequired

    styles :
        facebook :
            backgroundColor : "#395996"
            color           : "white"
        google   :
            backgroundColor : "#DC4839"
            color           : "white"
        twitter  :
            backgroundColor : "#55ACEE"
            color           : "white"
        github   :
            backgroundColor : "black"
            color           : "black"

    render_strategy : (name) ->
        if name is 'email'
            return
        <a href={"/auth/#{name}"} key={name}>
            <Icon size='2x' name='stack' href={"/auth/#{name}"}>
                {<Icon name='circle' stack='2x' style={color: @styles[name].backgroundColor} /> if name isnt 'github'}
                <Icon name={name} stack='1x' size={'2x' if name is 'github'} style={color: @styles[name].color} />
            </Icon>
        </a>

    render : ->
        <div style={textAlign: 'center'}>
            <h3 style={marginTop: 0}>Connect with</h3>
            <div>
                {@render_strategy(name) for name in @props.strategies}
            </div>
            <hr style={marginTop: 10, marginBottom: 10} />
        </div>

SignUp = rclass
    displayName: 'SignUp'

    propTypes :
        strategies : rtypes.array
        actions : rtypes.object.isRequired
        sign_up_error: rtypes.object
        token: rtypes.bool
        has_account : rtypes.bool
        signing_up : rtypes.bool
        style: rtypes.object

    make_account : (e) ->
        e.preventDefault()
        name = @refs.name.getValue()
        email = @refs.email.getValue()
        password = @refs.password.getValue()
        token = @refs.token?.getValue()
        @props.actions.sign_this_fool_up(name, email, password, token)

    display_error : (field)->
        if @props.sign_up_error?[field]?
            <div style={color: "red", fontSize: "90%"}>{@props.sign_up_error[field]}</div>

    display_passports : ->
        if not @props.strategies?
            return <Loading />
        if @props.strategies.length > 1
            return <Passports actions={@props.actions} strategies={@props.strategies} />

    display_token_input : ->
        if @props.token
            <Input ref='token' type='text' placeholder='Enter the secret token' />

    render : ->
        <Well>
            {@display_token_input()}
            {@display_error("token")}
            {@display_passports()}
            <h3 style={marginTop: 0, textAlign: 'center'} >Create an Account</h3>
            <form style={marginTop: 20, marginBottom: 20} onSubmit={@make_account}>
                {@display_error("first_name")}
                <Input ref='name' type='text' autoFocus={not @props.has_account} placeholder='First and Last Name' />
                {@display_error("email_address")}
                <Input ref='email' type='email' placeholder='Email address' />
                {@display_error("password")}
                <Input ref='password' type='password' placeholder='Choose a password' />
                <div style={fontSize: "small", textAlign: "center"}>
                    By clicking Sign up! you agree to our <a target="_blank" href="/policies/terms.html">Terms of Service</a>.
                </div>
                <Button style={marginBottom: UNIT, marginTop: UNIT}
                    disabled={@props.signing_up}
                    bsStyle="success"
                    bsSize='large'
                    type='submit'
                    block>
                        {<Icon name="spinner" spin /> if @props.signing_up} Sign up!
                    </Button>
            </form>
            <div style={textAlign: "center"}>
                Email <HelpEmailLink /> if you need help.
            </div>
        </Well>

SignIn = rclass
    displayName : "SignIn"

    propTypes :
        actions : rtypes.object.isRequired
        sign_in_error : rtypes.string
        signing_in : rtypes.bool
        has_account : rtypes.bool

    sign_in : (e) ->
        e.preventDefault()
        @props.actions.sign_in(@refs.email.getValue(), @refs.password.getValue())

    display_forgot_password : ->
        @props.actions.setTo(show_forgot_password : true)

    display_error : ->
        if @props.sign_in_error?
            <ErrorDisplay error={@props.sign_in_error} onClose={=>@props.actions.setTo(sign_in_error: undefined)} style={width : "56ex", marginRight : "37px"} />

    remove_error : ->
        if @props.sign_in_error
            @props.actions.setTo(sign_in_error : undefined)

    render : ->
        <Col sm=7>
            <Row className='form-inline pull-right'>
                <form onSubmit={@sign_in} className='form-inline pull-right' style={marginRight : -4 * UNIT, marginTop : 20}>
                    <Col xs=4>
                        <Input style={marginRight : UNIT} ref='email' bsSize="small" type='email' placeholder='Email address' autoFocus={@props.has_account} onChange={@remove_error} />
                    </Col>
                    <Col xs=4>
                        <Input style={marginRight : UNIT} ref='password' bsSize="small" type='password' placeholder='Password' onChange={@remove_error} />
                        <Row>
                            <a onClick={@display_forgot_password} style={marginLeft: UNIT + 11, cursor: "pointer", fontSize: 12} >Forgot Password?</a>
                        </Row>
                    </Col>
                    <Col xs=4>
                        <Button type="submit" disabled={@props.signing_in} bsStyle="primary" bsSize="small" >Sign in</Button>
                    </Col>
                </form>
            </Row>
            <Row className='form-inline pull-right' style={clear : "right"}>
                {@display_error()}
            </Row>
        </Col>

ForgotPassword = rclass
    displayName : "ForgotPassword"

    mixins: [ImmutablePureRenderMixin]

    propTypes :
        actions : rtypes.object.isRequired
        forgot_password_error : rtypes.string
        forgot_password_success : rtypes.string

    forgot_password : (e) ->
        e.preventDefault()
        @props.actions.forgot_password(@refs.email.getValue())

    display_error : ->
        if @props.forgot_password_error?
            <span style={color: "red", fontSize: "90%"}>{@props.forgot_password_error}</span>

    display_success : ->
        if @props.forgot_password_success?
            <span style={color: "green", fontSize: "90%"}>{@props.forgot_password_success}</span>

    hide_forgot_password : ->
        @props.actions.setTo(show_forgot_password : false)
        @props.actions.setTo(forgot_password_error : undefined)
        @props.actions.setTo(forgot_password_success : undefined)

    render : ->
        <Modal show={true} onHide={@hide_forgot_password}>
            <Modal.Body>
                <div>
                    <h1>Forgot Password?</h1>
                    Enter your email address to reset your password
                </div>
                <form onSubmit={@forgot_password}>
                    {@display_error()}
                    {@display_success()}
                    <Input ref='email' type='email' placeholder='Email address' />
                    <hr />
                    Not working? Email us at <HelpEmailLink />
                    <Row>
                        <div style={textAlign: "right", paddingRight : 15}>
                            <Button type="submit" bsStyle="primary" bsSize="medium" style={marginRight : 10}>Send email</Button>
                            <Button onClick={@hide_forgot_password} bsSize="medium">Cancel</Button>
                        </div>
                    </Row>
                </form>
            </Modal.Body>
        </Modal>

ResetPassword = rclass
    propTypes : ->
        actions : rtypes.object.isRequired
        reset_key : rtypes.string.isRequired
        reset_password_error : rtypes.string

    mixins: [ImmutablePureRenderMixin]

    reset_password : (e) ->
        e.preventDefault()
        @props.actions.reset_password(@props.reset_key, @refs.password.getValue())

    hide_reset_password : (e) ->
        e.preventDefault()
        history.pushState("", document.title, window.location.pathname)
        @props.actions.setTo(reset_key : '', reset_password_error : '')

    display_error : ->
        if @props.reset_password_error
            <span style={color: "red", fontSize: "90%"}>{@props.reset_password_error}</span>

    render : ->
        <Modal show={true} onHide={=>x=0}>
            <Modal.Body>
                <div>
                    <h1>Reset Password?</h1>
                    Enter your new password
                </div>
                <form onSubmit={@reset_password}>
                    <Input ref='password' type='password' placeholder='New Password' />
                    {@display_error()}
                    <hr />
                    Not working? Email us at <HelpEmailLink />
                    <Row>
                        <div style={textAlign: "right", paddingRight : 15}>
                            <Button type="submit" bsStyle="primary" bsSize="medium" style={marginRight : 10}>Reset password</Button>
                            <Button onClick={@hide_reset_password} bsSize="medium">Cancel</Button>
                        </div>
                    </Row>
                </form>
            </Modal.Body>
        </Modal>

ContentItem = rclass
    displayName: "ContentItem"

    mixins: [ImmutablePureRenderMixin]

    propTypes:
        icon: rtypes.string.isRequired
        heading: rtypes.string.isRequired
        text: rtypes.string.isRequired

    render : ->
        <Row>
            <Col sm=2>
                <h1 style={textAlign: "center"}><Icon name={@props.icon} /></h1>
            </Col>
            <Col sm=10>
                <h2 style={fontFamily: "'Roboto Mono','monospace'"}>{@props.heading}</h2>
                {@props.text}
            </Col>
        </Row>

LANDING_PAGE_CONTENT =
    teaching :
        icon : 'university'
        heading : 'Tools for Teaching'
        text : 'Create projects for your students, hand out assignments, then collect and grade them with ease.'
    collaboration :
        icon : 'weixin'
        heading : 'Collaboration Made Easy'
        text : 'Edit documents with multiple team members in real time.'
    programming :
        icon : 'code'
        heading : 'All-in-one Programming'
        text : 'Write, compile and run code in nearly any programming language.'
    math :
        icon : 'area-chart'
        heading : 'Computational Mathematics'
        text : 'Use SageMath, IPython, the entire scientific Python stack, R, Julia, GAP, Octave and much more.'
    latex :
        icon : 'superscript'
        heading : 'Built-in LaTeX Editor'
        text : 'Write beautiful documents using LaTeX.'

LandingPageContent = rclass
    displayName : 'LandingPageContent'

    mixins: [ImmutablePureRenderMixin]

    render : ->
        <div style={backgroundColor: "white", color: BS_BLUE}>
            {<ContentItem icon={v.icon} heading={v.heading} key={k} text={v.text} /> for k, v of LANDING_PAGE_CONTENT}
        </div>
    ###
    componentDidMount : ->
        @update_mathjax()

    componentDidUpdate : ->
        @update_mathjax()

    update_mathjax: ->
        el = ReactDOM.findDOMNode(@)
        MathJax.Hub.Queue(["Typeset",MathJax.Hub,el]);
    ###

SagePreview = rclass
    displayName : "SagePreview"

    render : ->
        <div className="hidden-xs">
            <Well>
                <Row>
                    <Col sm=6>
                        <ExampleBox title="Interactive Worksheets" index={0}>
                            Interactively explore mathematics, science and statistics. <strong>Collaborate with others in real time</strong>. You can see their cursors moving around while they type &mdash; this works for Sage Worksheets and even Jupyter Notebooks!
                        </ExampleBox>
                    </Col>
                    <Col sm=6>
                        <ExampleBox title="Course Management" index={1}>
                            <SiteName /> helps to you to <strong>conveniently organize a course</strong>: add students, create their projects, see their progress,
                            understand their problems by dropping right into their files from wherever you are.
                            Conveniently handout assignments, collect them, grade them, and finally return them.
                            (<a href="https://github.com/sagemathinc/smc/wiki/Teaching" target="_blank">SMC used for Teaching</a> and <a href="http://www.beezers.org/blog/bb/2015/09/grading-in-sagemathcloud/" target="_blank">learn more about courses</a>).
                        </ExampleBox>
                    </Col>
                </Row>
                <br />
                <Row>
                    <Col sm=6>
                      <ExampleBox title="LaTeX Editor" index={2}>
                            <SiteName /> supports authoring documents written in LaTeX, Markdown or HTML.
                            The <strong>preview</strong> helps you understanding what&#39;s going on.
                            The LaTeX editor also supports <strong>forward and inverse search</strong> to avoid getting lost in large documents.
                        </ExampleBox>
                    </Col>
                    <Col sm=6>
                        <ExampleBox title="The Sky is the Limit" index={3}>
                            <SiteName /> does not arbitrarily restrict you.
                            <strong>Upload</strong> your own files, <strong>generate</strong> data and results online,
                            then download or <strong>publish</strong> your results.
                            Besides Sage Worksheets and Jupyter Notebooks,
                            you can work with a <strong>full Linux terminal</strong> and edit text with multiple cursors.
                        </ExampleBox>
                    </Col>
                </Row>
            </Well>
        </div>

example_image_style =
    border       : '1px solid #aaa'
    borderRadius : '3px'
    padding      : '5px'
    background   : 'white'
    height       : '236px'

ExampleBox = rclass
    displayName : "ExampleBox"

    propTypes :
        title   : rtypes.string.isRequired
        index   : rtypes.number.isRequired

    render : ->
        <div>
            <h3 style={marginBottom:UNIT, fontFamily: "'Roboto Mono','monospace'"} >{@props.title}</h3>
            <div style={marginBottom:'5px'} >
                <img alt={@props.title} className = 'smc-grow-two' src="#{images[@props.index]}" style={example_image_style} />
            </div>
            <div>
                {@props.children}
            </div>
        </div>

LogoWide = rclass
    displayName: "LogoWide"
    render : ->
        <div style={fontSize: 3*UNIT,\
                    whiteSpace: 'nowrap',\
                    backgroundColor: SAGE_LOGO_COLOR,\
                    borderRadius : 4,\
                    display: 'inline-block',\
                    padding: 1,\
                    margin: UNIT + 'px 0',\
                    lineHeight: 0}>
          <span style={display: 'inline-block', \
                       backgroundImage: 'url("/static/salvus-icon.svg")', \
                       backgroundSize: 'contain', \
                       height : UNIT * 4, width: UNIT * 4, \
                       borderRadius : 10, \
                       verticalAlign: 'center'}>
          </span>
          <div className="hidden-sm"
              style={display:'inline-block',\
                      fontFamily: "'Roboto Mono','monospace'",\
                      top: -1 * UNIT,\
                      position: 'relative',\
                      color: 'white',\
                      paddingRight: UNIT}><SiteName /></div>
        </div>

RememberMe = () ->
    <Well style={fontSize : "25px"}>
        <Icon name="spinner" spin /> Signing you in...
    </Well>


LandingPageFooter = rclass
    displayName : "LandingPageFooter"

    mixins: [ImmutablePureRenderMixin]

    render: ->
        <div style={textAlign: "center", fontSize: "small", padding: 2*UNIT + "px"}>
        SageMath, Inc. &middot; <a target="_blank" href="/policies/index.html">Policies</a> &middot; <a target="_blank" href="/policies/terms.html">Terms of Service</a> &middot; <HelpEmailLink />
        </div>

exports.LandingPage = rclass
    propTypes:
        actions : rtypes.object.isRequired
        strategies : rtypes.array
        sign_up_error : rtypes.object
        sign_in_error : rtypes.string
        signing_in : rtypes.bool
        signing_up : rtypes.bool
        forgot_password_error : rtypes.string
        forgot_password_success : rtypes.string #is this needed?
        show_forgot_password : rtypes.bool
        token : rtypes.bool
        reset_key : rtypes.string
        reset_password_error : rtypes.string
        remember_me : rtypes.bool
        has_account : rtypes.bool

    render : ->
        reset_key = reset_password_key()
        <div style={marginLeft: 20, marginRight: 20}>
            {<ResetPassword reset_key={reset_key}
                            reset_password_error={@props.reset_password_error}
                            actions={@props.actions} /> if reset_key}
            {<ForgotPassword actions={@props.actions}
                             forgot_password_error={@props.forgot_password_error}
                             forgot_password_success={@props.forgot_password_success} /> if @props.show_forgot_password}
            <Row>
                <Col sm=12>
                    <Row>
                        <Col sm=5 className="hidden-xs">
                            <LogoWide />
                        </Col>
                        {<SignIn actions={@props.actions}
                                 signing_in={@props.signing_in}
                                 sign_in_error={@props.sign_in_error}
                                 has_account={@props.has_account} /> if not @props.remember_me}
                    </Row>
                    <Row className="hidden-xs">
                        <Col sm=12>
                            <SiteDescription />
                        </Col>
                    </Row>
                </Col>
            </Row>
            <Row>
                <Col sm=7 className="hidden-xs">
                    <LandingPageContent />
                </Col>
                <Col sm=5>
                    {<SignUp actions={@props.actions}
                             sign_up_error={@props.sign_up_error}
                             strategies={@props.strategies}
                             token={@props.token}
                             signing_up={@props.signing_up}
                             has_account={@props.has_account} /> if not @props.remember_me}
                    {<RememberMe /> if @props.remember_me}
                </Col>
            </Row>
            <br />
            <SagePreview />
            <LandingPageFooter />
        </div>