require! './lib/trace': {Trace}

export TraceTool = (scope, layer, canvas) ->
    ractive = this

    trace = new Trace scope, ractive
    trace-tool = new scope.Tool!
        ..onMouseDrag = (event) ~>
            # panning
            offset = event.downPoint .subtract event.point
            scope.view.center = scope.view.center .add offset
            canvas.style.cursor = 'grabbing'
            trace.pause!

        ..onMouseUp = (event) ~>
            layer.activate!
            if scope.project.hitTest event.point
                # that is a hit
                if trace.load that.segment
                    console.log "we are continuing!"
            trace.add-segment event.point
            canvas.style.cursor = 'cell'
            trace.resume!

        ..onMouseMove = (event) ~>
            if trace.continues
                trace.follow event.point
            else
                trace.highlight-target event.point

        ..onKeyDown = (event) ~>
            trace.set-modifiers event.modifiers
            switch event.key
            | \escape =>
                if trace.continues
                    trace.end!
                else
                    #ractive.find-id \toolChanger .fire \select, {}, \sl
                    ractive.set \currTool, \sl
            | 'v' =>
                trace.add-via!
            | 'e' =>
                unless event.modifiers.shift
                    trace.remove-last-point!
                else
                    trace.remove-last-point \undo

    return trace-tool
