module TermLayouts

using Preferences

const DEBUG_IO = Ref{IOStream}()

function debug_open_pwd!()
  if isassigned(DEBUG_IO) && isopen(DEBUG_IO[])
    close(DEBUG_IO[])
  end
  DEBUG_IO[] = open(joinpath(pwd(), "termlayouts.log"), "w")
end
function close_debug!()
  isassigned(DEBUG_IO) && isopen(DEBUG_IO[]) && close(DEBUG_IO[])
end
macro debugmsg(msg)
  filename = basename(string(__source__.file))
  lines = string(__source__.line)
  src = "$(filename):$(lines)"
  quote
    if isassigned(DEBUG_IO) && isopen(DEBUG_IO[])
      msg_string = string($(esc(msg)))
      println(DEBUG_IO[], "DEBUG[", $src, "]: ", msg_string)
      flush(DEBUG_IO[])
    else
      error("bad DEBUG_IO: $(DEBUG_IO)")
    end
  end
end

include("core.jl")
include("parseANSI.jl")
include("config.jl")
include("io.jl")
include("errors.jl")
include("strings.jl")

"Loads TermLayouts preferences from the environment"
function loadprefs()
  panelL_width = @load_preference("panelL_width", 70)
  panelL_title = @load_preference("panelL_title", "")
  panelL_title_color = @load_preference("panelL_title_color", "")
  panelL_border_color = @load_preference("panelL_border_color", "red")

  panelR_width = @load_preference("panelR_width", 30)
  panelR_title = @load_preference("panelR_title", "")
  panelR_title_color = @load_preference("panelR_title_color", "")
  panelR_border_color = @load_preference("panelR_border_color", "blue")

  if (panelL_width + panelR_width) > 100
    @warn "Panel widths add up to more than 100, cropping right panel"
    panelR_width = 100 - panelL_width
  end

  panelL_prefs = PanelPrefs(panelL_width, panelL_title, panelL_title_color, panelL_border_color)
  panelR_prefs = PanelPrefs(panelR_width, panelR_title, panelR_title_color, panelR_border_color)

  return TermLayoutsPreferences(panelL_prefs, panelR_prefs)
end

"Activate TermLayouts, and spawn a new REPL session"
function run()
  debug_open_pwd!()
  @debugmsg "hey!"
  @debugmsg "hey!"
  @debugmsg "hey!"

  state = TermLayoutsState()
  prefs = loadprefs()

  # Create pipes
  inputpipe = Pipe()
  outputpipe = Pipe()
  errpipe = Pipe()

  Base.link_pipe!(inputpipe, reader_supports_async=true, writer_supports_async=true)
  Base.link_pipe!(outputpipe, reader_supports_async=true, writer_supports_async=true)
  Base.link_pipe!(errpipe, reader_supports_async=true, writer_supports_async=true)

  true_stdout = stdout
  redirect_stdout(outputpipe.in)

  # Link pipes to REPL
  term = REPL.Terminals.TTYTerminal("dumb", inputpipe.out, outputpipe.in, errpipe.in)
  repl = REPL.LineEditREPL(term, true)
  repl.specialdisplay = REPL.REPLDisplay(repl)
  repl.history_file = false

  # Start REPL
  print(true_stdout, "starting REPL...")
  start_eval_backend(state)
  # hook_repl(repl, state)

  # Clear screen before proceeding
  # Still doesn't work on windows for some reason
  print(true_stdout, "\e[3J")
  print(true_stdout, "\e[1;1H")

  repltask = @async begin
    REPL.run_repl(repl)
  end

  # Setup some variables that describe the state of the REPL
  should_exit = false
  keyboard_io = stdin
  replstr = ""

  # Create a console-like object that will make it easier to parse ANSI commands
  virtual_console = EditableString([], 0, 0, "\e[0m")

  # Read output from REPL and process it asynchronously
  @async while !eof(outputpipe)
    @debugmsg "read..."
    data = String(readavailable(outputpipe))
    @debugmsg "read: > $(data)"

    # Read the output, and process it relative to the current state of the console
    try
      parseANSI(virtual_console, data, true)
      @debugmsg "read: parseANSI"
    catch e
      @debugmsg "read: parseANSI throws: $e"
    end
    sleep(1e-2)
  end

  # Render the layout asynchronously
  @async while !should_exit
    @debugmsg "render"
    # Create panels and give them default sizes
    fullh, fullw = displaysize(true_stdout)
    lpanelw = Int(round(fullw * prefs.panel1.width / 100))
    rpanelw = Int(round(fullw * prefs.panel2.width / 100))

    # Grab the string that describes the current state of the fake console, and set the panel's text to it
    outstr = to_string(virtual_console, true)
    # Reshape text
    reshaped = Term.reshape_text(outstr, lpanelw - 3)
    # Get last few lines
    reshaped_lines = split(reshaped, "\n")
    reshaped_cropped = reshaped_lines[max(1, length(reshaped_lines) - fullh + 3):end]

    last_line = string(reshaped_cropped[max(1, length(reshaped_cropped) - 1)])

    text_before_cursor = simplifyANSI(last_line, false)
    # TODO: Allow cursor to move around after
    cursorX = length(text_before_cursor) + 3
    cursorY = length(reshaped_cropped)

    final_outstr = join(reshaped_cropped, "\n")
    replstr = final_outstr

    # Create panels
    lpanel = Term.Panel(
      replstr,
      width=lpanelw,
      height=fullh,
      style="red"
    )
    rpanel = Term.Panel(
      width=rpanelw,
      height=fullh,
      style="blue"
    )
    top = lpanel * rpanel


    # Clear screen and print the panel
    # print(true_stdout, string(Term.Panel(
    #   top,
    #   width=fullw - 1,
    #   height=fullh - 2,
    # )))
    # print(true_stdout, "\e[2J")
    print(true_stdout, "\e[3J")
    print(true_stdout, "\e[1;1H")
    print(true_stdout, string(top))

    print(true_stdout, "\e[" * string(cursorY) * ";" * string(cursorX) * "H")

    sleep(1 / 30)
  end

  while !should_exit
    @debugmsg "main: enter"
    # Read in keys
    control_value = :CONTROL_VOID
    control_value = read_key(keyboard_io)
    @debugmsg "main: control_value=$control_value"

    # Exit on Ctrl+C
    if control_value == :EXIT
      should_exit = true
    else
      # Pass down keys to the REPL
      write(inputpipe.in, control_value)
    end
    sleep(1e-2)
  end
  @debugmsg "main: end"

  # Delete line (^U) and close REPL (^D)
  write(inputpipe.in, "\x15\x04")
  redirect_stdout(true_stdout)

  print(true_stdout, "\e[2J")
  print(true_stdout, "\e[3J")
  print(true_stdout, "\e[1;1H")

  Base.wait(repltask)
  t = @async begin
    close(inputpipe.in)
    close(outputpipe.in)
    close(errpipe.in)
  end
  Base.wait(t)

  @debugmsg "Exiting"
  close_debug!()
end

end
