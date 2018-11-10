require! 'dcs/lib/keypath': {get-keypath, set-keypath}
require! '../../kernel': {PaperDraw}

# basic methods that every component should have
export class ComponentBase
    ->
        @scope = new PaperDraw
        @ractive = @scope.ractive

    set-data: (keypath, value) ->
        set-keypath @g.data.aecad, keypath, value

    get-data: (keypath) ->
        get-keypath @g.data.aecad, keypath

    add-data: (keypath, value) ->
        curr = (@get-data keypath) or 0 |> parse-int
        set-keypath @g.data.aecad, keypath, curr + value

    send-to-layer: (layer-name) ->
        @g `@scope.send-to-layer` layer-name

    init-with-data: (first-arg) ->
        # detect if the component is initialized with
        # initialization data or being created from scratch
        #
        # Format:
        #   {
        #     init:
        #       item: Paper.js item
        #       parent: parent Component (optional)
        #   }
        if first-arg and \init of first-arg
            return first-arg.init
