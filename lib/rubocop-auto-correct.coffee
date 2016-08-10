{CompositeDisposable, BufferedProcess} = require 'atom'
{spawnSync} = require 'child_process'
which = require 'which'
path = require 'path'
fs = require 'fs-plus'
temp = require 'temp'

module.exports =
class RubocopAutoCorrect
  constructor: ->
    @subscriptions = new CompositeDisposable
    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      if editor.getGrammar().scopeName.match("ruby")
        @handleEvents(editor)

    @subscriptions.add atom.commands.add 'atom-workspace',
      'rubocop-auto-correct:current-file': => @run(atom.workspace.getActiveTextEditor())
      'rubocop-auto-correct:toggle-auto-run': => @toggleAutoRun()
      'rubocop-auto-correct:toggle-notification': => @toggleNotification()
      'rubocop-auto-correct:toggle-correct-file': => @toggleCorrectFile()
      'rubocop-auto-correct:toggle-debug-mode': => @toggleDebugMode()

  destroy: ->
    @subscriptions.dispose()

  handleEvents: (editor) ->
    buffer = editor.getBuffer()
    bufferSavedSubscription = buffer.onDidSave =>
      buffer.transact =>
        if atom.config.get('rubocop-auto-correct.autoRun')
          @run(editor)

    editorDestroyedSubscription = editor.onDidDestroy ->
      bufferSavedSubscription.dispose()
      editorDestroyedSubscription.dispose()

    @subscriptions.add(bufferSavedSubscription)
    @subscriptions.add(editorDestroyedSubscription)

  toggleMessage: (messagePrepend, enabled) ->
    "Rubocop Auto Correct: "+ messagePrepend + " " +
      (if enabled then "ON" else "OFF")

  toggleAutoRun: ->
    setting = atom.config.get('rubocop-auto-correct.autoRun')
    atom.config.set('rubocop-auto-correct.autoRun', !setting)
    atom.notifications.addSuccess(@toggleMessage("Auto Run", !setting))

  toggleNotification: ->
    setting = atom.config.get('rubocop-auto-correct.notification')
    atom.config.set('rubocop-auto-correct.notification', !setting)
    atom.notifications.addSuccess(@toggleMessage("Notifications", !setting))

  toggleCorrectFile: ->
    setting = atom.config.get('rubocop-auto-correct.correctFile')
    atom.config.set('rubocop-auto-correct.correctFile', !setting)
    atom.notifications.addSuccess(@toggleMessage("Correct File", !setting))

  toggleDebugMode: ->
    setting = atom.config.get('rubocop-auto-correct.debugMode')
    atom.config.set('rubocop-auto-correct.debugMode', !setting)
    atom.notifications.addSuccess(@toggleMessage("Debug Mode", !setting))

  run: (editor) ->
    if editor
      unless editor.getGrammar().scopeName.match("ruby")
        return atom.notifications.addError("Only use source.ruby")
      if atom.config.get('rubocop-auto-correct.correctFile')
        if editor.isModified()
          editor.save()
        @autoCorrectFile(editor.getPath())
      else
        @autoCorrectBuffer(editor.getBuffer())

  projectRootRubocopConfig: (filePath) ->
    [projectPath, relativePath] = atom.project.relativizePath(filePath)
    projectConfigPath = projectPath + '/.rubocop.yml'
    homeConfigPath = fs.getHomeDirectory() + '/.rubocop.yml'
    if (fs.existsSync(projectConfigPath))
      ['--config', projectConfigPath]
    else if (fs.existsSync(homeConfigPath))
      ['--config', homeConfigPath]
    else
      []

  rubocopCommand: ->
    commandWithArgs = atom.config.get('rubocop-auto-correct.rubocopCommandPath')
                                .split(/\s+/).filter((i) -> i)

    command = commandWithArgs[0]
    args = commandWithArgs[1..]

    which command, (err) ->
      if (err)
        return atom.notifications.addFatalError(
          "Rubocop command is not found.",
          { detail: '''
          When you don't install rubocop yet, Run `gem install rubocop` first.\n
          If you already installed rubocop, Please check package setting at `Rubocop Command Path`.
          ''' }
        )
    [command, args]

  autoCorrectBuffer: (buffer)  ->
    tempFilePath = @makeTempFile("rubocop.rb")
    fs.writeFileSync(tempFilePath, buffer.getText())

    rubocopCommand = @rubocopCommand()
    command = rubocopCommand[0]
    args = rubocopCommand[1]
      .concat(['-a', tempFilePath])
      .concat(@projectRootRubocopConfig(buffer.getPath()))

    rubocop = spawnSync(command, args, { encoding: 'utf-8', timeout: 5000 })

    if (rubocop.status != 0)
      @rubocopOutput(buffer.getBaseName(), rubocop.stderr)
    else
      buffer.setTextViaDiff(fs.readFileSync(tempFilePath, 'utf-8'))
      @rubocopOutput(buffer.getBaseName(), rubocop.stdout)

  autoCorrectFile: (filePath)  ->
    rubocopCommand = @rubocopCommand()
    command = rubocopCommand[0]
    args = rubocopCommand[1]
      .concat(['-a', filePath])
      .concat(@projectRootRubocopConfig(filePath))

    stdout = (output) =>
      @rubocopOutput(filePath.replace(/.+\//, ""), output)
    stderr = (output) =>
      @rubocopOutput(filePath.replace(/.+\//, ""), output)

    rubocop = new BufferedProcess({command, args, stdout, stderr})

  rubocopOutput: (fileName, output) ->
    debug = atom.config.get('rubocop-auto-correct.debugMode')
    notification = atom.config.get('rubocop-auto-correct.notification')
    console.log(output) if debug

    if output.match("corrected")
      re = /^.+?(:[0-9]+:[0-9]+:.*$)/mg
      offenses = output.match(re)
      offenses.map (offense) ->
        message = offense.replace(re, fileName + "$1")
        console.log(message) if debug
        atom.notifications.addWarning(message) if notification
    else if output.match("no offenses")
      atom.notifications.addSuccess(output) if notification
    else
      atom.notifications.addInfo(output) if notification

  makeTempFile: (filename) ->
    directory = temp.mkdirSync()
    filePath = path.join(directory, filename)
    fs.writeFileSync(filePath, '')
    filePath
