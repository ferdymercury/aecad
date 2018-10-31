require! 'prelude-ls': {empty, flatten, filter, map}
require! './lib/selection': {Selection}
require! '../kernel': {PaperDraw}
require! './lib/trace/lib': {get-tid, set-tid}

export SelectTool = ->
    # http://paperjs.org/tutorials/project-items/transforming-items/
    scope = new PaperDraw
    selection = new Selection

    sel =
        box: null

    select-tool = new scope.Tool!
        ..onMouseMove = (event) ~>
            scope.ractive.set \pointer, event.point

        ..onMouseDrag = (event) ~>
            # panning
            if event.modifiers.shift
                offset = event.downPoint .subtract event.point
                scope.view.center = scope.view.center .add offset
            else
                if sel.box
                    sel.box.segments
                        ..1.point.y = event.point.y
                        ..2.point.set event.point
                        ..3.point.x = event.point.x
                    sel.box.selected = yes

        ..onMouseUp = (event) ->
            if sel.box
                s = that.segments
                opts = {}
                if s.0.point.subtract s.2.point .length > 10
                    if s.0.point.x < s.2.point.x
                        # selection is left to right
                        opts.inside = sel.box.bounds
                    else
                        # selection is right to left
                        opts.overlapping = sel.box.bounds

                    selection.add scope.project.getItems opts
                sel.box.remove!

        ..onMouseDown = (event) ~>
            # TODO: there are many objects overlapped, use .hitTestAll() instead
            hit = scope.project.hitTest event.point
            console.log "Select Tool: Hit result is: ", hit
            unless event.modifiers.control
                selection.clear!

            unless hit
                # Create the selection box
                sel.box = new scope.Path.Rectangle do
                    from: event.point
                    to: event.point
                    fill-color: \white
                    opacity: 0.4
                    stroke-width: 0
                    data:
                        tmp: \true
                        role: \selection

            else
                # Select the clicked item
                if hit.item.data?tmp
                    console.log "...selected a temporary item, doing nothing"
                    return
                scope.project.activeLayer.bringToFront!

                select-item = ~>
                    selection.add if @get \selectGroup
                        hit.item.parent
                    else
                        hit.item

                if get-tid hit.item
                    # this is related to a trace, handle specially
                    if event.modifiers.control
                        # select the whole trace
                        console.log "adding whole trace to selection because Ctrl is pressed."
                        select-item!
                    else
                        if hit.item.data.aecad.type is \via-part
                            via = hit.item.parent
                            selection.add via
                        else if hit.segment
                            # Segment of a trace
                            segment = hit.segment
                            #console.log "...selecting the segment of trace: ", hit
                            selection.add segment
                        else if hit.location
                            # Curve of a trace
                            curve = hit.location.curve
                            #console.log "...selecting the curve of trace:", hit

                            selection.add {name: \tmp, role: \handle, item: curve} # for visualization

                            handle =
                                left: curve.point1
                                right: curve.point2

                            console.log "Handle is: ", handle

                            /*
                            for name, item of handle
                                console.log "adding handle points for movement:", item
                                selection.add {
                                    name,
                                    item,
                                    strength: \weak
                                    role: \handle}
                                    , {-select}
                            */

                            # silently select all parts which are touching to the ends
                            for part in hit.item.parent.children
                                #console.log "examining trace part: ", part
                                if part.data?.aecad?.type in <[ via ]>
                                    #console.log "...found via: ", part
                                    for name, point of handle
                                        if point.isClose part.bounds.center, 1
                                            strength = \weak
                                            #console.log "adding via to #{name} (#{strength})", part
                                            selection.add {
                                                name,
                                                strength,
                                                role: \via
                                                item: part}
                                                , {-select}
                                else
                                    # find mate segments
                                    for mate-seg in part.getSegments!
                                        for name, hpoint of handle when mate-seg.point.isClose hpoint, 1
                                            strength = \weak
                                            console.log "adding #{name} mate point: ", mate-seg.point
                                            selection.add {
                                                name,
                                                strength,
                                                role: \mate-mpoint
                                                item: mate-seg.point}
                                                , {-select}

                                            # add the solver
                                            # -----------------------------------
                                            # input: point
                                            # algorithm: the input point has to be on handle curve
                                            # output: intersection point of mate line and handle.

                                            mate-fp = null # mate far point
                                            for [mate-seg.next, mate-seg.previous] when ..?
                                                for n, hpoint of handle when n isnt name
                                                    unless hpoint.equals ..point
                                                        mate-fp = ..point

                                            unless mate-fp
                                                # this is handler tip
                                                continue

                                            #console.log "far point is: ", mate-fp
                                            #console.log "mate angle isss: ", (mate-seg.point.subtract mate-fp).angle
                                            marker = (center, color, tooltip) ->
                                                radius = 4
                                                new scope.Path.Circle({
                                                    center, radius
                                                    fill-color: color
                                                    data: {+tmp}
                                                    opacity: 0.3
                                                    stroke-color: color
                                                    })

                                            get-solver = (m1, m2, h1, h2) ->
                                                console.log "Adding solver for mate: ", m1, m2
                                                marker m1, \red
                                                marker m2, \blue
                                                hline = scope._Line {p1: h1, p2: h2}
                                                    ..rotate 0, {+inplace, +round}

                                                mline = scope._Line {p1: m1, p2: m2}
                                                    ..rotate 0, {+inplace, +round}
                                                #console.log "handle angle: ", hline.getAngle(), "mate angle: ", mline.getAngle!
                                                return solver = (delta) ->
                                                    #console.log "solving #{name} side for delta: ", delta
                                                    hline.move delta
                                                    isec = hline.intersect mline
                                                    isec.subtract m1

                                            selection.add {
                                                name,
                                                role: \solver,
                                                solver: get-solver(mate-seg.point, mate-fp, handle.left, handle.right)
                                                }
                                                , {-select}

                            #console.log "selected everything needed: ", selection.selected
                            for side in <[ left right ]>
                                _sel = selection.filter (.name is side)
                                console.log "...#{side}: ", _sel
                                if [.. for _sel when ..solver?].length > 1
                                    scope.vlog.error "#{side} shouldn't have more than one solver!"

                        else
                            scope.vlog.error "What did you select of trace id #{get-tid hit.item}"


                else if hit.item
                    # select normally
                    select-item!
                else
                    console.error "What did we hit?", hit
                    debugger

        ..onKeyDown = (event) ~>
            switch event.key
            | \delete =>
                # delete an item with Delete key
                scope.history.commit!
                selection.delete!
            | \escape =>
                # Press Esc to cancel a cache
                selection.deselect!
            | \a =>
                if event.modifiers.control
                    selection.add scope.get-all!
                    event.preventDefault!
            | \z =>
                if event.modifiers.control
                    scope.history.back!
            |_ =>
                if event.modifiers.shift
                    scope.cursor \grab

        ..onKeyUp = (event) ->
            scope.cursor \default

    scope.add-tool \select, select-tool
    select-tool
