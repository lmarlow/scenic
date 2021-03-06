#
#  Created by Boyd Multerer on 2018-04-07.
#  Copyright © 2018 Kry10 Industries. All rights reserved.
#
# Taking the learnings from several previous versions.

defmodule Scenic.Scene do
  alias Scenic.Graph
  alias Scenic.Scene
  alias Scenic.ViewPort
  alias Scenic.ViewPort.Context
  alias Scenic.Primitive
  alias Scenic.Utilities

  require Logger

  # import IEx

  @moduledoc """

  ## Overview

  Scenes are the core of the UI model.

  A `Scene` has three jobs.

  1. Maintain any state specific to that part of your application.
  1. Build and maintain a graph of UI primitives that gets drawn
  to the screen.
  2. Handle input and events.

  ### A brief aside

  Before saying anything else I want to emphasize that the rest of your
  application, meaning device control logic, sensor reading / writing,
  services, whatever, does not need to have anything to do with Scenes.

  In many cases I recommend treating those as separate GenServers in their
  own supervision trees that you maintain. Then your Scenes would query or send
  information to/from them via cast or call messages.

  Part of the point of using Erlang/Elixir/OTP is separating this sort of
  logic into independent trees. That way, an error in one part of your
  application does not mean the rest of it will fail.

  ## Scenes

  So.. scenes are the core of the UI model. A scene consists of one ore more
  graphs, and a set of event handlers and filters to deal with user input
  and other messages.

  Think of a scene as being a little like an HTML page. HTML pages have:

  * Structure (the DOM)
  * Logic (Javascript)
  * Links to other pages.

  A Scene has:

  * Structure (graphs),
  * Logic (event handlers and filters)
  * Transitions to other scenes. Well... it can request the [`ViewPort`](overview_viewport.html)
  to go to a different scene.

  Your application is a collection of scenes that are in use at various times. There
  is only ever **one** scene showing in a [`ViewPort`](overview_viewport.html) at a given
  time. However, scenes can reference other scenes, effectively embedding their graphs
  inside the main one. More on that below.


  ### [Graphs](Scenic.Graph.html)

  Each scene should maintain at least one graph. You can build graphs
  at compile time, or dynamically while your scene is running. Building
  them at compile time has two advantages

    1. Performance: It is clearly faster to build the graph once during
    build time than to build it repeatedly during runtime.
    2. Error checking: If your graph has an error in it, it is much
    better to have it stop compilation than cause an error during runtime.

  Example of building a graph during compile time:

    @graph  graph.build(font_size: 24)
    |> button({"Press Me", :button_id}, translate: {20, 20})



  Rather than having a single scene maintain a massive graph of UI,
  graphs can reference graphs in other scenes.

  On a typical screen of UI, there is one scene
  that is the root. Each control, is its own scene process with
  its own state. These child scenes can in turn contain other
  child scenes. This allows for strong code reuse, isolates knowledge
  and logic to just the pieces that need it, and keeps the size of any
  given graph to a reasonable size. For example, The
  handlers of a check-box scene don't need to know anything about
  how a slider works, even though they are both used in the same
  parent scene. At best, they only need to know that they
  both conform to the `Component.Input` behavior, and can thus
  query or set each others value. Though it is usually
  the parent scene that does that.

  The application developer is responsible for building and
  maintaining the scene's graph. It only enters the world of the
  `ViewPort` when you call `push_graph`. Once you have called
  `push_graph`, that graph is sent to the drivers and is out of your
  immediate control. You update that graph by calling `push_graph`
  again.

  This does mean you could maintain two separate graphs
  and rapidly switch back and forth between them via push_graph.
  I have not yet hit a good use case for that.

  #### Graph ID.

  This is an advanced feature...

  Each scene has a default graph id of nil. When you send a graph
  to the ViewPort by calling `push_graph(graph)`, you are really
  sending it with a sub-id of nil. This encourages thinking that
  scenes and graphs have a 1:1 relationship. There are, however,
  times that you want a single scene to host multiple graphs that
  can refer to each other via sub-ids. You would push them
  like this: `push_graph(graph, id)`. Where the id is any term you
  would like to use as a key.

  There are several use cases where this makes sense.
  1) You have a complex tree (perhaps a lot of text) that you want
  to animate. Rather than re-rendering the text (relatively expensive)
  every time you simply transform a rotation matrix, you could place
  the text into its own static sub-graph and then refer to it
  from the primary. This will save energy as you animate.

  2) Both the Remote and Recording clients make heavy use of sub-ids
  to make sense of the graph being replayed.

  The downside of using graph_ids comes with input handling.
  because you have a single scene handling the input events for
  multiple graphs, you will need to take extra care to correctly
  handle position-dependent events, which may not be projected
  into the coordinate space you think they are. The Remote and
  Recording clients deal with this by rendering a single, completely
  transparent rect above all the sub scenes. This invisible, yet
  present rect hits all the position dependent events and makes
  sure they are sent to the scene projected in to the main
  (id is nil) graph's coordinate space.


  ### Communications

  Scenes are specialized GenServers. As such, they communicate with each other
  (and the rest of your application) through messages. You can receive
  messages with the standard `handle_info`, `handle_cast`, `handle_call` callbacks just
  like any other scene.

  Scenes have two new event handling callbacks that you can *optionally* implement. These
  are about user input vs UI events.


  ## Input vs. Events

  Input is data generated by the drivers and sent up to the scenes
  through the `ViewPort`. There is a limited set of input types and
  they are standardized so that the drivers can be built independently
  of the scenes. Input follows certain rules about which scene receives them

  Events are messages that one scene generates for consumption
  by other scenes. For example, a `Component.Button` scene would
  generate a `{:click, msg}` event that is sent to its parent
  scene.

  You can generate any message you want, however, the standard
  component libraries follow certain patterns to keep things sensible.

  ## Input Handling

  You handle incoming input events by adding `handle_input/3` functions
  to your scene. Each `handle_input/3` call passes in the input message
  itself, an input context struct, and your scene's state. You can
  then take the appropriate actions, including generating events
  (below) in response.

  Under normal operation, input that is not position dependent
  (keys, window events, more...) is sent to the root scene. Input
  that does have a screen position (cursor_pos, cursor button
  presses, etc...) Is sent to the scene that contains the
  graph that was hit.

  Your scene can "capture" all input of a given type so that
  it is sent to itself instead of the default scene for that type.
  this is how a text input field receives the key input. First,
  the user selects that field by clicking on it. In response
  to the cursor input, the text field captures text input (and
  maybe transforms its graph to show that it is selected).

  Captured input types should be released when no longer
  needed so that normal operation can resume.

  The input messages are passed on to a scene's parent if
  not processed.

  ## Event Filtering

  In response to input, (or anything else... a timer perhaps?),
  a scene can generate an event (any term), which is sent backwards
  up the tree of scenes that make up the current aggregate graph.

  In this way, a `Component.Button` scene can generate a`{:click, msg}`
  event that is sent to its parent. If the parent doesn't
  handle it, it is sent to that scene's parent. And so on until the
  event reaches the root scene. If the root scene doesn't handle
  it either then the event is dropped.

  To handle events, you add `filter_event/3` functions to your scene.
  This function handles the event, and stop its progress backwards
  up the graph. It can handle it and allow it to continue up the
  graph. Or it can transform the event and pass the transformed
  version up the graph.

  You choose the behavior by returning either

      {:cont, msg, state}

  or

      {:halt, state}

  Parameters passed in to `filter_event/3` are the event itself, a
  reference to the originating scene (which you can to communicate
  back to it), and your scene's state.

  A pattern I'm using is to handle and event at the filter and stop
  its progression. It also generates and sends new event to its
  parent. I do this instead of transforming and continuing when
  I want to change the originating scene.


  ## No children

  There is an optimization you can use. If you know for certain that your component
  will not attempt to use any components, you can set `has_children` to `false` like this.

      use Scenic.Component, has_children: false

  Setting `has_children` to `false` this will do two things. First, it won't create
  a dynamic supervisor for this scene, which saves some resources.

  For example, the Button component sets `has_children` to `false`.
  """

  # @viewport             :viewport
  @not_activated :__not_activated__

  @type response_opts ::
          list(
            {:timeout, non_neg_integer}
            | {:hibernate, true}
            | {:continue, term}
            | {:push, graph :: Graph.t()}
          )

  defmodule Error do
    @moduledoc false
    defexception message: nil
  end

  # ============================================================================
  # client api - working with the scene

  @doc """
  send a filterable event to a scene.

  This is very similar in feel to casting a message to a GenServer. However,
  This message will be handled by the Scene's `filter_event\3` function. If the
  Scene returns `{:continue, msg, state}` from `filter_event\3`, then the event
  will also be sent to the scene's parent. This will continue until the message
  reaches the root scene or some other permanently supervised scene.

  Typically, when a scene wants to initiate an event, it will call `send_event/1`
  which is a private function injected into the scene during `use Scenic.Scene`

  This private version of send_event will take care of the housekeeping of
  tracking the parent's pid. It will, in turn, call this function on the main
  Scene module to send the event on its way.

      def handle_input( {:cursor_button, {:left, :release, _, _}}, _, %{msg: msg} = state ) do
        send_event( {:click, msg} )
        {:noreply, state}
      end

  On the other hand, if you know you want to send the event to a named scene
  that you supervise yourself, then you would use `Scenic.Scene.send_event/2`

      def handle_input( {:cursor_button, {:left, :release, _, _}}, _, %{msg: msg} = state ) do
        Scenic.Scene.send_event( :some_scene, {:click, msg} )
        {:noreply, state}
      end

  Be aware that named scenes that your supervise yourself are unable to continue
  the event to their parent in the graph because they could be referenced by
  multiple graphs making the continuation ambiguous.
  """

  @spec send_event(scene_server :: GenServer.server(), event :: ViewPort.event()) :: :ok
  def send_event(scene_server, {evt, _} = event) when is_atom(evt) do
    GenServer.cast(scene_server, {:event, event, self()})
  end

  # --------------------------------------------------------
  @doc """
  cast a message to a scene.
  """
  def cast(scene_or_graph_key, msg) do
    with {:ok, pid} <- ViewPort.Tables.get_scene_pid(scene_or_graph_key) do
      GenServer.cast(pid, msg)
    end
  end

  # --------------------------------------------------------
  def cast_to_refs(graph_key_or_id, msg)

  def cast_to_refs({:graph, _, _} = graph_key, msg) do
    with {:ok, refs} <- ViewPort.Tables.get_refs(graph_key) do
      Enum.each(refs, fn {_, key} -> cast(key, msg) end)
    end
  end

  def cast_to_refs(sub_id, msg) do
    case Process.get(:scene_ref) do
      nil ->
        "cast_to_refs requires a full graph_key or must be called within a scene"
        |> raise()

      scene_ref ->
        cast_to_refs({:graph, scene_ref, sub_id}, msg)
    end
  end

  # ============================================================================
  # callback definitions

  @doc """
  Invoked when the `Scene` receives input from a driver.

  Input is messages sent directly from a driver, usually based on some action by the user.
  This is opposed to "events", which are generated by other scenes.

  When input arrives at a scene, you can consume it, or pass it along to the scene above
  you in the ViewPort's supervision structure.

  To consume the input and have processing stop afterward, return either a `{:halt, ...}` or
  `{:noreply, ...}` value. They are effectively the same thing.

  To allow the scene's parent to process the input, return `{:cont, input, state, ...}`. Note
  that you can pass along the input unchanged or transform it in the process if you wish.

  The callback supports all the return values of the
  [`init`](https://hexdocs.pm/elixir/GenServer.html#c:handle_cast/2)
  callback in [`Genserver`](https://hexdocs.pm/elixir/GenServer.html).

  In addition to the normal return values defined by GenServer, a `Scene` can
  add an optional `{push: graph}` term, which pushes the graph to the viewport.

  This has replaced push_graph() as the preferred way to push a graph.
  """
  @callback handle_input(input :: any, context :: Context.t(), state :: any) ::
              {:noreply, new_state}
              | {:noreply, new_state}
              | {:noreply, new_state, timeout}
              | {:noreply, new_state, :hibernate}
              | {:noreply, new_state, opts :: response_opts()}
              | {:halt, new_state}
              | {:halt, new_state, timeout}
              | {:halt, new_state, :hibernate}
              | {:halt, new_state, opts :: response_opts()}
              | {:cont, input, new_state}
              | {:cont, input, new_state, timeout}
              | {:cont, input, new_state, :hibernate}
              | {:cont, input, new_state, opts :: response_opts()}
              | {:stop, reason, new_state}
            when new_state: term, reason: term, input: term

  @doc """
  Invoked when the `Scene` receives an event from another scene.

  Events are messages generated by a scene, that are passed backwards up the ViewPort's
  scene supervision tree. This is opposed to "input", which comes directly from the drivers.

  When an event arrives at a scene, you can consume it, or pass it along to the scene above
  you in the ViewPort's supervision structure.

  To consume the input and have processing stop afterward, return either a `{:halt, ...}` or
  `{:noreply, ...}` value. They are effectively the same thing.

  To allow the scene's parent to process the input, return `{:cont, event, state, ...}`. Note
  that you can pass along the event unchanged or transform it in the process if you wish.

  The callback supports all the return values of the
  [`init`](https://hexdocs.pm/elixir/GenServer.html#c:handle_cast/2)
  callback in [`Genserver`](https://hexdocs.pm/elixir/GenServer.html).

  In addition to the normal return values defined by GenServer, a `Scene` can
  add an optional `{push: graph}` term, which pushes the graph to the viewport.

  This has replaced push_graph() as the preferred way to push a graph.
  """
  @callback filter_event(event :: term, from :: pid, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state}
              | {:noreply, new_state, timeout}
              | {:noreply, new_state, :hibernate}
              | {:noreply, new_state, opts :: response_opts()}
              | {:halt, new_state}
              | {:halt, new_state, timeout}
              | {:halt, new_state, :hibernate}
              | {:halt, new_state, opts :: response_opts()}
              | {:cont, event, new_state}
              | {:cont, event, new_state, timeout}
              | {:cont, event, new_state, :hibernate}
              | {:cont, event, new_state, opts :: response_opts()}
              | {:stop, reason, new_state}
            when new_state: term, reason: term, event: term

  @doc """
  Invoked when the `Scene` is started.

  `args` is the argument term you passed in via config or ViewPort.set_root.

  `options` is a list of information giving you context about the environment
  the scene is running in. If an option is not in the list, then it should be
  treated as nil.
    * `:viewport` - This is the pid of the ViewPort that is managing this dynamic scene.
      It will be not set, or nil, if you are managing the Scene in a static
      supervisor yourself.
    * `:styles` - This is the map of styles that your scene can choose to inherit
      (or not) from its parent scene. This is typically used by a child control that
      wants to visually fit into its parent's look.
    * `:id` - This is the :id term that the parent set a component when it was invoked.

  The callback supports all the return values of the
  [`init`](https://hexdocs.pm/elixir/GenServer.html#c:init/1)
  callback in [`Genserver`](https://hexdocs.pm/elixir/GenServer.html).

  In addition to the normal return values defined by GenServer, a `Scene` can
  return two new ones that push a graph to the viewport

  Returning `{:ok, state, push: graph}` will push the indicated graph
  to the ViewPort. This is preferable to the old push_graph() function.
  """

  @callback init(args :: term, options :: list) ::
              {:ok, new_state}
              | {:ok, new_state, timeout :: non_neg_integer}
              | {:ok, new_state, :hibernate}
              | {:ok, new_state, opts :: response_opts()}
              | :ignore
              | {:stop, reason :: any}
            when new_state: any

  @doc """
  Invoked to handle synchronous `call/3` messages. `call/3` will block until a
  reply is received.

  The callback supports all the return values of the
  [`handle_call`](https://hexdocs.pm/elixir/GenServer.html#c:handle_call/3)
  callback in [`Genserver`](https://hexdocs.pm/elixir/GenServer.html).

  In addition to the normal return values defined by GenServer, a `Scene` can
  add an optional `{push: graph}` term, which pushes the graph to the viewport.

  This has replaced push_graph() as the preferred way to push a graph.
  """
  @callback handle_call(request :: term, from :: GenServer.from(), state :: term) ::
              {:reply, reply, new_state}
              | {:reply, reply, new_state, timeout}
              | {:reply, reply, new_state, :hibernate}
              | {:reply, reply, new_state, opts :: response_opts()}
              | {:noreply, new_state}
              | {:noreply, new_state, timeout}
              | {:noreply, new_state, :hibernate}
              | {:noreply, new_state, opts :: response_opts()}
              | {:stop, reason, reply, new_state}
              | {:stop, reason, new_state}
            when reply: term, new_state: term, reason: term

  @doc """
  Invoked to handle asynchronous `cast/2` messages.

  `request` is the request message sent by a `cast/2` and `state` is the current
  state of the `Scene`.

  The callback supports all the return values of the
  [`handle_cast`](https://hexdocs.pm/elixir/GenServer.html#c:handle_cast/2)
  callback in [`Genserver`](https://hexdocs.pm/elixir/GenServer.html).

  In addition to the normal return values defined by GenServer, a `Scene` can
  add an optional `{push: graph}` term, which pushes the graph to the viewport.

  This has replaced push_graph() as the preferred way to push a graph.
  """
  @callback handle_cast(request :: term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout}
              | {:noreply, new_state, :hibernate}
              | {:noreply, new_state, opts :: response_opts()}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @doc """
  Invoked to handle all other messages.

  `msg` is the message and `state` is the current state of the `Scene`. When
  a timeout occurs the message is `:timeout`.

  Return values are the same as `c:handle_cast/2`.

  In addition to the normal return values defined by GenServer, a `Scene` can
  add an optional `{push: graph}` term, which pushes the graph to the viewport.

  This has replaced push_graph() as the preferred way to push a graph.
  """
  @callback handle_info(msg :: :timeout | term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout}
              | {:noreply, new_state, :hibernate}
              | {:noreply, new_state, opts :: response_opts()}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @doc """
  Invoked to handle `continue` instructions.

  It is useful for performing work after initialization or for splitting the work
  in a callback in multiple steps, updating the process state along the way.

  The callback supports all the return values of the
  [`handle_continue`](https://hexdocs.pm/elixir/GenServer.html#c:handle_continue/2)
  callback in [`Genserver`](https://hexdocs.pm/elixir/GenServer.html).

  In addition to the normal return values defined by GenServer, a `Scene` can
  add an optional `{push: graph}` term, which pushes the graph to the viewport.

  This has replaced push_graph() as the preferred way to push a graph.
  """
  @callback handle_continue(continue :: term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout}
              | {:noreply, new_state, :hibernate}
              | {:noreply, new_state, opts :: response_opts()}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @doc """
  Invoked when the Scene is about to exit. It should do any cleanup required.

  `reason` is exit reason and `state` is the current state of the `Scene`.
  The return value is ignored.

  The callback identical to the
  [`terminate`](https://hexdocs.pm/elixir/GenServer.html#c:terminate/2)
  callback in [`Genserver`](https://hexdocs.pm/elixir/GenServer.html).
  """
  @callback terminate(reason, state :: term) :: term
            when reason: :normal | :shutdown | {:shutdown, term}

  # ============================================================================
  # using macro

  # ===========================================================================
  # the using macro for scenes adopting this behavior
  defmacro __using__(using_opts \\ []) do
    quote do
      @behaviour Scenic.Scene

      # --------------------------------------------------------
      # Here so that the scene can override if desired
      # def init(_, _, _),                            do: {:ok, nil}

      @doc false
      def handle_call(_msg, _from, state), do: {:reply, :err_not_handled, state}
      @doc false
      def handle_cast(_msg, state), do: {:noreply, state}
      @doc false
      def handle_info(_msg, state), do: {:noreply, state}
      @doc false
      def handle_continue(_msg, state), do: {:noreply, nil, state}

      @doc false
      def handle_input(event, _, scene_state), do: {:noreply, scene_state}
      @doc false
      def filter_event(event, _from, scene_state), do: {:cont, event, scene_state}

      @doc false
      def terminate(_reason, _scene_state), do: :ok

      @doc false
      def start_dynamic_scene(supervisor, parent, args, opts \\ []) do
        has_children =
          case unquote(using_opts)[:has_children] do
            false -> false
            _ -> true
          end

        Scenic.Scene.start_dynamic_scene(
          supervisor,
          parent,
          __MODULE__,
          args,
          opts,
          has_children
        )
      end

      defp send_event(event_msg) do
        case Process.get(:parent_pid) do
          nil -> {:error, :no_parent}
          pid -> GenServer.cast(pid, {:event, event_msg, self()})
        end
      end

      defp push_graph(%Graph{} = graph) do
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecation in #{inspect(__MODULE__)}

        push_graph/1 has been deprecated and will be removed in a future version
        Instead, use the returns below

        from init/2
            {:ok, state, push: graph}

        from filter_event/3
            {:halt, state, push: graph}
            {:cont, event, state, push: graph}

        from handle_cast/2
            {:noreply, state, push: graph}

        from handle_info/2
            {:noreply, state, push: graph}

        from handle_call/3
            {:reply, reply, state, push: graph}
            {:noreply, state, push: graph}

        from handle_continue/3
            {:noreply, state, push: graph}
        #{IO.ANSI.default_color()}
        """)

        GenServer.cast(self(), {:push_graph, graph, nil})
        # return the graph so this can be pipelined
        graph
      end

      # return the local scene process's scene_ref
      defp scene_ref(), do: Process.get(:scene_ref)

      # child spec that really starts up scene, with this module as an option
      @doc false
      def child_spec({args, opts}) when is_list(opts) do
        %{
          id: make_ref(),
          start: {Scenic.Scene, :start_link, [__MODULE__, args, opts]},
          type: :worker,
          restart: :permanent,
          shutdown: 500
        }
      end

      # --------------------------------------------------------
      # add local shortcuts to things like get/put graph and modify element
      # do not add a put element. keep it at modify to stay atomic
      # --------------------------------------------------------
      defoverridable handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     handle_input: 3,
                     filter_event: 3,
                     start_dynamic_scene: 3,
                     terminate: 2

      # quote
    end

    # defmacro
  end

  # ===========================================================================
  # calls for setting up a scene inside of a supervisor

  #  def child_spec({ref, scene_module}), do:
  #    child_spec({ref, scene_module, nil})

  @doc false
  def child_spec({scene_module, args, opts}) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [scene_module, args, opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  # ============================================================================
  # internal server api
  @doc false
  def start_link(scene_module, args, opts \\ []) do
    init_data = {scene_module, args, opts}

    case opts[:name] do
      nil ->
        GenServer.start_link(__MODULE__, init_data)

      name ->
        GenServer.start_link(__MODULE__, init_data, name: name)
    end
  end

  # --------------------------------------------------------
  @doc false
  def init({scene_module, args, opts}) do
    has_children =
      case opts[:has_children] do
        false -> false
        _ -> true
      end

    scene_ref = opts[:scene_ref] || opts[:name]
    Process.put(:scene_ref, scene_ref)

    # if this is being built as a viewport's dynamic root, let the vp know it is up.
    # this solves the case where this scene is dynamic and has crashed and is recovering.
    # The scene_ref is the same, but the pid has changed. This lets the vp know which
    # is the correct pid to use when it is cleaned up later.
    case opts[:vp_dynamic_root] do
      nil ->
        nil

      viewport ->
        GenServer.cast(viewport, {:dyn_root_up, scene_ref, self()})
    end

    # interpret the options
    parent_pid =
      case opts[:parent] do
        nil ->
          nil

        parent_pid ->
          # stash the parent pid away in the process dictionary. This
          # is for fast lookup during the injected send_event/1 in the
          # client module
          Process.put(:parent_pid, parent_pid)
          parent_pid
      end

    # if this scene is named... Meaning it is supervised by the app and is not a
    # dynamic scene, then we need monitor the ViewPort. If the viewport goes
    # down while this scene is activated, the scene will need to be able to
    # deactivate itself while the viewport is recovering. This is especially
    # true since the viewport may recover to a different default scene than this.
    if opts[:name], do: Process.monitor(Scenic.ViewPort.Tables)

    # build up the state
    state = %{
      has_children: has_children,
      raw_scene_refs: %{},
      dyn_scene_pids: %{},
      dyn_scene_keys: %{},
      parent_pid: parent_pid,
      children: %{},
      scene_module: scene_module,
      viewport: opts[:viewport],
      # scene_state: sc_state,
      # scene_state: nil,
      scene_ref: scene_ref,
      supervisor_pid: nil,
      dynamic_children_pid: nil,
      activation: @not_activated
    }

    {:ok, state, {:continue, {:__scene_init_2__, scene_module, args, opts}}}
  end

  # ============================================================================
  # terminate

  def terminate(reason, %{scene_module: mod, scene_state: sc_state}) do
    mod.terminate(reason, sc_state)
  end

  # ============================================================================
  # handle_continue

  # --------------------------------------------------------
  def handle_continue(
        {:__scene_init_2__, scene_module, args, opts},
        %{scene_ref: scene_ref} = state
      ) do
    # get the scene supervisors
    [supervisor_pid | _] =
      self()
      |> Process.info()
      |> get_in([:dictionary, :"$ancestors"])

    # make sure it is a pid and not a name
    supervisor_pid =
      case supervisor_pid do
        name when is_atom(name) -> Process.whereis(name)
        pid when is_pid(pid) -> pid
      end

    # make sure this is a Scene.Supervisor, not something else
    {supervisor_pid, dynamic_children_pid} =
      case Process.info(supervisor_pid) do
        nil ->
          {nil, nil}

        info ->
          case get_in(info, [:dictionary, :"$initial_call"]) do
            {:supervisor, Scene.Supervisor, _} ->
              dynamic_children_pid =
                Supervisor.which_children(supervisor_pid)
                # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                |> Enum.find_value(fn
                  {DynamicSupervisor, pid, :supervisor, [DynamicSupervisor]} -> pid
                  _ -> nil
                end)

              {supervisor_pid, dynamic_children_pid}

            _ ->
              {nil, nil}
          end
      end

    # register the scene in the scenes ets table
    Scenic.ViewPort.Tables.register_scene(
      scene_ref,
      {self(), dynamic_children_pid, supervisor_pid}
    )

    # store bookeeping in the state
    state =
      state
      |> Map.put(:supervisor_pid, supervisor_pid)
      |> Map.put(:dynamic_children_pid, dynamic_children_pid)
      |> Map.put(:scene_state, nil)

    # set up to init the module
    # GenServer.cast(self(), {:init_module, scene_module, args, opts})

    # reply with the state so far
    {:noreply, state, {:continue, {:__scene_init_3__, scene_module, args, opts}}}
  end

  # --------------------------------------------------------
  def handle_continue({:__scene_init_3__, scene_module, args, opts}, state) do
    # initialize the scene itself
    try do
      # handle the result of the scene init and return
      case scene_module.init(args, opts) do
        {:ok, sc_state} ->
          deal_with_noreply(:noreply, state, sc_state)

        {:ok, sc_state, opt} ->
          deal_with_noreply(:noreply, state, sc_state, opt)

        :ignore ->
          :ignore

        {:stop, reason} ->
          {:stop, reason}

        unknown ->
          # build error message components
          head_msg = "#{inspect(scene_module)} init returned invalid response"
          err_msg = ""
          args_msg = "return value: #{inspect(unknown)}"
          stack_msg = ""

          unless Mix.env() == :test do
            [
              "\n",
              IO.ANSI.red(),
              head_msg,
              "\n",
              IO.ANSI.yellow(),
              args_msg,
              IO.ANSI.default_color()
            ]
            |> Enum.join()
            |> IO.puts()
          end

          case opts[:viewport] do
            nil ->
              :ok

            vp ->
              msgs = {head_msg, err_msg, args_msg, stack_msg}
              ViewPort.set_root(vp, {Scenic.Scenes.Error, {msgs, scene_module, args}})
          end

          {:noreply, state}
      end
    rescue
      err ->
        # build error message components
        module_msg = inspect(scene_module)
        err_msg = inspect(err)
        args_msg = inspect(args)
        stack_msg = Exception.format_stacktrace(__STACKTRACE__)

        # assemble into a final message to output to the command line
        unless Mix.env() == :test do
          [
            "\n",
            IO.ANSI.red(),
            module_msg <> "crashed during init",
            "\n",
            IO.ANSI.yellow(),
            "Scene Args:" <> args_msg,
            "\n",
            IO.ANSI.red(),
            err_msg,
            "\n",
            "--> ",
            stack_msg,
            "\n",
            IO.ANSI.default_color()
          ]
          |> Enum.join()
          |> IO.puts()
        end

        case opts[:viewport] do
          nil ->
            :ok

          vp ->
            msgs = {module_msg, err_msg, args_msg, stack_msg}
            ViewPort.set_root(vp, {Scenic.Scenes.Error, {msgs, scene_module, args}})
        end

        # purposefully slow down the reply in the event of a crash. Just in
        # case it does go into a crazy loop
        # Process.sleep(400)
        {:noreply, state}
    end
  end

  # --------------------------------------------------------
  # generic handle_continue. give the scene a chance to handle it
  @doc false
  def handle_continue(msg, %{scene_module: mod, scene_state: sc_state} = state) do
    case mod.handle_continue(msg, sc_state) do
      {:noreply, sc_state} -> deal_with_noreply(:noreply, state, sc_state)
      {:noreply, sc_state, opt} -> deal_with_noreply(:noreply, state, sc_state, opt)
      {:stop, reason, sc_state} -> {:stop, reason, %{state | scene_state: sc_state}}
    end
  end

  # ============================================================================
  # handle_info

  # --------------------------------------------------------
  # generic handle_info. give the scene a chance to handle it
  @doc false
  def handle_info(msg, %{scene_module: mod, scene_state: sc_state} = state) do
    case mod.handle_info(msg, sc_state) do
      {:noreply, sc_state} -> deal_with_noreply(:noreply, state, sc_state)
      {:noreply, sc_state, opt} -> deal_with_noreply(:noreply, state, sc_state, opt)
      {:stop, reason, sc_state} -> {:stop, reason, %{state | scene_state: sc_state}}
    end
  end

  # ============================================================================
  # handle_call

  # --------------------------------------------------------
  # generic handle_call. give the scene a chance to handle it
  def handle_call(msg, from, %{scene_module: mod, scene_state: sc_state} = state) do
    case mod.handle_call(msg, from, sc_state) do
      {:reply, reply, sc_state} -> deal_with_reply(reply, state, sc_state)
      {:reply, reply, sc_state, opt} -> deal_with_reply(reply, state, sc_state, opt)
      {:noreply, sc_state} -> deal_with_noreply(:noreply, state, sc_state)
      {:noreply, sc_state, opt} -> deal_with_noreply(:noreply, state, sc_state, opt)
      {:stop, reason, sc_state} -> {:stop, reason, %{state | scene_state: sc_state}}
    end
  end

  # ============================================================================
  # handle_cast

  # --------------------------------------------------------
  def handle_cast(
        {:input, event, %Scenic.ViewPort.Context{viewport: vp, raw_input: raw_input} = context},
        %{scene_module: mod, scene_state: sc_state} = state
      ) do
    case mod.handle_input(event, context, sc_state) do
      {:noreply, sc_state} ->
        deal_with_noreply(:noreply, state, sc_state)

      {:noreply, sc_state, opts} ->
        deal_with_noreply(:noreply, state, sc_state, opts)

      {:halt, sc_state} ->
        deal_with_noreply(:noreply, state, sc_state)

      {:halt, sc_state, opts} ->
        deal_with_noreply(:noreply, state, sc_state, opts)

      {:cont, sc_state} ->
        GenServer.cast(vp, {:continue_input, raw_input})
        deal_with_noreply(:noreply, state, sc_state)

      {:cont, sc_state, opts} ->
        GenServer.cast(vp, {:continue_input, raw_input})
        deal_with_noreply(:noreply, state, sc_state, opts)

      {:stop, sc_state} ->
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecated handle_input :stop return in #{inspect(mod)}
        Please return {:halt, state} instead
        This resolves a naming conflict with the newer GenServer return values
        #{IO.ANSI.default_color()}
        """)

        deal_with_noreply(:noreply, state, sc_state)

      {:stop, sc_state, opts} ->
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecated handle_input :stop return in #{inspect(mod)}
        Please return {:halt, state} instead
        This resolves a naming conflict with the newer GenServer return values
        #{IO.ANSI.default_color()}
        """)

        deal_with_noreply(:noreply, state, sc_state, opts)

      {:continue, sc_state} ->
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecated handle_input :continue return in #{inspect(mod)}
        Please return {:cont, state} instead
        This resolves a naming conflict with the newer GenServer return values
        #{IO.ANSI.default_color()}
        """)

        GenServer.cast(vp, {:continue_input, raw_input})
        deal_with_noreply(:noreply, state, sc_state)

      {:continue, sc_state, opts} ->
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecated handle_input :continue return in #{inspect(mod)}
        Please return {:cont, state} instead
        This resolves a naming conflict with the newer GenServer return values
        #{IO.ANSI.default_color()}
        """)

        GenServer.cast(vp, {:continue_input, raw_input})
        deal_with_noreply(:noreply, state, sc_state, opts)
    end
  end

  # --------------------------------------------------------
  def handle_cast(
        {:event, event, from_pid},
        %{
          parent_pid: parent_pid,
          scene_module: mod,
          scene_state: sc_state
        } = state
      ) do
    case mod.filter_event(event, from_pid, sc_state) do
      {:noreply, sc_state} ->
        deal_with_noreply(:noreply, state, sc_state)

      {:noreply, sc_state, opts} ->
        deal_with_noreply(:noreply, state, sc_state, opts)

      {:halt, sc_state} ->
        deal_with_noreply(:noreply, state, sc_state)

      {:halt, sc_state, opts} ->
        deal_with_noreply(:noreply, state, sc_state, opts)

      {:cont, event, sc_state} ->
        GenServer.cast(parent_pid, {:event, event, from_pid})
        deal_with_noreply(:noreply, state, sc_state)

      {:cont, event, sc_state, opts} ->
        GenServer.cast(parent_pid, {:event, event, from_pid})
        deal_with_noreply(:noreply, state, sc_state, opts)

      {:stop, sc_state} ->
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecated filter_event :stop return in #{inspect(mod)}
        Please return {:halt, state} instead
        This resolves a naming conflict with the newer GenServer return values
        #{IO.ANSI.default_color()}
        """)

        deal_with_noreply(:noreply, state, sc_state)

      {:stop, sc_state, opts} ->
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecated filter_event :stop return in #{inspect(mod)}
        Please return {:halt, state} instead
        This resolves a naming conflict with the newer GenServer return values
        #{IO.ANSI.default_color()}
        """)

        deal_with_noreply(:noreply, state, sc_state, opts)

      {:continue, event, sc_state} ->
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecated filter_event :continue return in #{inspect(mod)}
        Please return {:cont, state} instead
        This resolves a naming conflict with the newer GenServer return values
        #{IO.ANSI.default_color()}
        """)

        GenServer.cast(parent_pid, {:event, event, from_pid})
        deal_with_noreply(:noreply, state, sc_state)

      {:continue, event, sc_state, opts} ->
        IO.puts("""
        #{IO.ANSI.yellow()}
        Deprecated filter_event :continue return in #{inspect(mod)}
        Please return {:cont, state} instead
        This resolves a naming conflict with the newer GenServer return values
        #{IO.ANSI.default_color()}
        """)

        GenServer.cast(parent_pid, {:event, event, from_pid})
        deal_with_noreply(:noreply, state, sc_state, opts)
    end
  end

  # --------------------------------------------------------
  def handle_cast({:push_graph, graph, sub_id}, state) do
    {:ok, state} = internal_push_graph(graph, sub_id, state)
    {:noreply, state}
  end

  # --------------------------------------------------------
  # generic handle_cast. give the scene a chance to handle it
  def handle_cast({:stop, dyn_sup}, %{supervisor_pid: nil} = state) do
    DynamicSupervisor.terminate_child(dyn_sup, self())
    {:noreply, state}
  end

  # --------------------------------------------------------
  # generic handle_cast. give the scene a chance to handle it
  def handle_cast({:stop, dyn_sup}, %{supervisor_pid: supervisor_pid} = state) do
    DynamicSupervisor.terminate_child(dyn_sup, supervisor_pid)
    {:noreply, state}
  end

  # --------------------------------------------------------
  # generic handle_cast. give the scene a chance to handle it
  def handle_cast(msg, %{scene_module: mod, scene_state: sc_state} = state) do
    case mod.handle_cast(msg, sc_state) do
      {:noreply, sc_state} -> deal_with_noreply(:noreply, state, sc_state)
      {:noreply, sc_state, opt} -> deal_with_noreply(:noreply, state, sc_state, opt)
      {:stop, reason, sc_state} -> {:stop, reason, %{state | scene_state: sc_state}}
    end
  end

  # ============================================================================
  # Scene management

  # --------------------------------------------------------
  # this a root-level dynamic scene
  @doc false
  def start_dynamic_scene(dynamic_supervisor, parent, mod, args, opts, has_children)
      when is_list(opts) and is_boolean(has_children) and is_atom(mod) do
    ref = make_ref()

    opts =
      opts
      |> Keyword.put_new(:parent, parent)
      |> Keyword.put_new(:scene_ref, ref)

    do_start_child_scene(dynamic_supervisor, ref, mod, args, opts, has_children)
  end

  # --------------------------------------------------------
  defp do_start_child_scene(dynamic_supervisor, ref, mod, args, opts, true) do
    opts = Keyword.put(opts, :has_children, true)

    # start the scene supervision tree
    {:ok, supervisor_pid} =
      DynamicSupervisor.start_child(
        dynamic_supervisor,
        {Scenic.Scene.Supervisor, {mod, args, opts}}
      )

    # we want to return the pid of the scene itself. not the supervisor
    scene_pid =
      Supervisor.which_children(supervisor_pid)
      |> Enum.find_value(fn
        {_, pid, :worker, [Scenic.Scene]} ->
          pid

        _ ->
          nil
      end)

    {:ok, scene_pid, ref}
  end

  # --------------------------------------------------------
  defp do_start_child_scene(dynamic_supervisor, ref, mod, args, opts, false) do
    opts = Keyword.put(opts, :has_children, true)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        dynamic_supervisor,
        {Scenic.Scene, {mod, args, opts}}
      )

    {:ok, pid, ref}
  end

  # ============================================================================
  # push_graph

  if Mix.env() == :test do
    def test_push_graph(graph, sub_id, state) do
      internal_push_graph(graph, sub_id, state)
    end
  end

  # --------------------------------------------------------
  # def internal_push_graph( {graph, sub_id}, state ) do
  #   internal_push_graph( graph, sub_id, state )
  # end

  # not set up for dynamic children. Take the fast path
  def internal_push_graph(
        %Graph{} = graph,
        sub_id,
        %{
          has_children: false,
          scene_ref: scene_ref
        } = state
      ) do
    graph_key = {:graph, scene_ref, sub_id}

    # reduce the incoming graph to its minimal form
    # while simultaneously extracting the SceneRefs
    {graph, all_keys} =
      Enum.reduce(graph.primitives, {%{}, %{}}, fn
        # named reference
        {uid, %{module: Primitive.SceneRef, data: name} = p}, {g, all_refs} when is_atom(name) ->
          g = Map.put(g, uid, Primitive.minimal(p))
          all_refs = Map.put(all_refs, uid, {:graph, name, nil})
          {g, all_refs}

        # explicit reference
        {uid, %{module: Primitive.SceneRef, data: {:graph, _, _} = ref} = p}, {g, all_refs} ->
          g = Map.put(g, uid, Primitive.minimal(p))
          all_refs = Map.put(all_refs, uid, ref)
          {g, all_refs}

        # dynamic reference
        # Log an error and remove the ref from the graph
        {_uid, %{module: Primitive.SceneRef, data: {_, _} = ref}}, {g, all_refs} ->
          message = """
          Attempting to manage dynamic reference on graph with "has_children set to false
          reference: #{inspect(ref)}
          """

          raise Error, message: message

          {g, all_refs}

        # all non-SceneRef primitives
        {uid, p}, {g, all_refs} ->
          {Map.put(g, uid, Primitive.minimal(p)), all_refs}
      end)

    # insert the proper graph keys back into the graph to finish normalizing
    # it for the drivers. Yes, the driver could do this from the all_keys term
    # that is also being written into the :ets table, but it gets done all the
    # time for each reader and when consuming input, so it is better to do it
    # once here. Note that the all_keys term is still being written because
    # otherwise the drivers would need to do a full graph scan in order to prep
    # whatever translators they need. Again, the info has already been
    # calculated here, so just pass it along without throwing it out.
    graph =
      Enum.reduce(all_keys, graph, fn {uid, key}, g ->
        put_in(g, [uid, :data], {Scenic.Primitive.SceneRef, key})
      end)

    # write the graph into the ets table
    ViewPort.Tables.insert_graph(graph_key, self(), graph, all_keys)

    # write the graph into the ets table
    # ViewPort.Tables.insert_graph(graph_key, self(), graph, all_keys)

    {:ok, state}
  end

  # --------------------------------------------------------
  # push a graph to the ets table and manage embedded dynamic child scenes
  # to the reader: You have no idea how difficult this was to get right.
  def internal_push_graph(
        %Graph{} = raw_graph,
        sub_id,
        %{
          has_children: true,
          scene_ref: scene_ref,
          raw_scene_refs: old_raw_refs,
          dyn_scene_pids: old_dyn_pids,
          dyn_scene_keys: old_dyn_keys,
          dynamic_children_pid: dyn_sup,
          viewport: viewport
        } = state
      ) do
    # reduce the incoming graph to its minimal form
    # while simultaneously extracting the SceneRefs
    # this should be the only full scan when pushing a graph
    {graph, all_keys, new_raw_refs} =
      Enum.reduce(raw_graph.primitives, {%{}, %{}, %{}}, fn
        # named reference
        {uid, %{module: Primitive.SceneRef, data: name} = p}, {g, all_refs, dyn_refs}
        when is_atom(name) ->
          g = Map.put(g, uid, Primitive.minimal(p))
          all_refs = Map.put(all_refs, uid, {:graph, name, nil})
          {g, all_refs, dyn_refs}

        # explicit reference
        {uid, %{module: Primitive.SceneRef, data: {:graph, _, _} = ref} = p},
        {g, all_refs, dyn_refs} ->
          g = Map.put(g, uid, Primitive.minimal(p))
          all_refs = Map.put(all_refs, uid, ref)
          {g, all_refs, dyn_refs}

        # dynamic reference
        # don't add to all_refs yet. Will add after it is started (or not)
        {uid, %{module: Primitive.SceneRef, data: {_, _} = ref} = p}, {g, all_refs, dyn_refs} ->
          g = Map.put(g, uid, Primitive.minimal(p))
          dyn_refs = Map.put(dyn_refs, uid, ref)
          {g, all_refs, dyn_refs}

        # all non-SceneRef primitives
        {uid, p}, {g, all_refs, dyn_refs} ->
          {Map.put(g, uid, Primitive.minimal(p)), all_refs, dyn_refs}
      end)

    # get the difference script between the raw and new dynamic refs
    raw_diff = Utilities.Map.difference(old_raw_refs, new_raw_refs)

    # Use the difference script to determine what to start or stop.
    {new_dyn_pids, new_dyn_keys} =
      Enum.reduce(raw_diff, {old_dyn_pids, old_dyn_keys}, fn
        # start this dynamic scene
        {:put, uid, {mod, init_data}}, {old_pids, old_keys} ->
          unless dyn_sup do
            raise "You have set a dynamic SceneRef on a graph in a scene where has_children is false"
          end

          styles = Graph.style_stack(raw_graph, uid)

          # prepare the startup options to send to the new scene
          id = Map.get(raw_graph.primitives[uid], :id)

          init_opts =
            case viewport do
              nil -> [styles: styles, id: id]
              vp -> [viewport: vp, styles: styles, id: id]
            end

          # start the dynamic scene
          {:ok, pid, ref} = mod.start_dynamic_scene(dyn_sup, self(), init_data, init_opts)

          # tell the old scene to stop itself
          case old_pids[uid] do
            nil -> :ok
            old_pid -> GenServer.cast(old_pid, {:stop, dyn_sup})
          end

          # add the this dynamic child scene to tracking
          {
            Map.put(old_pids, uid, pid),
            Map.put(old_keys, uid, {:graph, ref, nil})
          }

        # stop this dynaic scene
        {:del, uid}, {old_pids, old_keys} ->
          # get the old dynamic graph reference
          pid = old_pids[uid]

          # send the optional deactivate message and terminate. ok to be async
          Task.start(fn ->
            GenServer.call(pid, :deactivate)
            GenServer.cast(pid, {:stop, dyn_sup})
          end)

          # remove old pid and key
          {Map.delete(old_pids, uid), Map.delete(old_keys, uid)}
      end)

    # merge all_refs with the managed dyanmic keys
    all_keys = Map.merge(all_keys, new_dyn_keys)

    graph_key = {:graph, scene_ref, sub_id}

    # insert the proper graph keys back into the graph to finish normalizing
    # it for the drivers. Yes, the driver could do this from the all_keys term
    # that is also being written into the :ets table, but it gets done all the
    # time for each reader and when consuming input, so it is better to do it
    # once here. Note that the all_keys term is still being written because
    # otherwise the drivers would need to do a full graph scan in order to prep
    # whatever translators they need. Again, the info has already been
    # calculated here, so just pass it along without throwing it out.
    graph =
      Enum.reduce(all_keys, graph, fn {uid, key}, g ->
        put_in(g, [uid, :data], {Scenic.Primitive.SceneRef, key})
      end)

    # write the graph into the ets table
    ViewPort.Tables.insert_graph(graph_key, self(), graph, all_keys)

    # store the refs for next time
    state =
      state
      |> Map.put(:raw_scene_refs, new_raw_refs)
      |> Map.put(:dyn_scene_pids, new_dyn_pids)
      |> Map.put(:dyn_scene_keys, new_dyn_keys)

    {:ok, state}
  end

  # ============================================================================
  # response management

  defp deal_with_noreply(type, state, sc_state, opts \\ nil) do
    case deal_with_response_opts(opts, state) do
      {nil, state} -> {type, %{state | scene_state: sc_state}}
      {opt, state} -> {type, %{state | scene_state: sc_state}, opt}
    end
  end

  defp deal_with_reply(reply, state, sc_state, opts \\ nil)

  defp deal_with_reply(reply, state, sc_state, opts) do
    case deal_with_response_opts(opts, state) do
      {nil, state} -> {:reply, reply, %{state | scene_state: sc_state}}
      {opt, state} -> {:reply, reply, %{state | scene_state: sc_state}, opt}
    end
  end

  defp deal_with_response_opts(opts, state)
  defp deal_with_response_opts(nil, state), do: {nil, state}
  defp deal_with_response_opts(timeout, state) when is_integer(timeout), do: {timeout, state}
  defp deal_with_response_opts({:continue, term}, state), do: {{:continue, term}, state}

  defp deal_with_response_opts(opts, state) when is_list(opts) do
    {:ok, state} =
      case opts[:push] do
        %Graph{} = graph -> internal_push_graph(graph, nil, state)
        {%Graph{} = graph, sub_id} -> internal_push_graph(graph, sub_id, state)
        _ -> {:ok, state}
      end

    opts
    |> Keyword.delete(:push)
    |> case do
      [{:timeout, timeout}] -> {timeout, state}
      [{:continue, term}] -> {{:continue, term}, state}
      _ -> {nil, state}
    end
  end
end
