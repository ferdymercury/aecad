# global imports
require! 'prelude-ls': {
    find, empty, unique, difference, max, keys, flatten, filter, values
    first, unique-by, compact, map, intersection, reject, or-list, Obj
}

require! 'aea': {merge}

# deps
require! './deps': {find-comp, PaperDraw, text2arr, get-class, get-aecad, parse-params}
require! './lib': {parse-name, next-id, flatten-obj}

# Class parts
require! './bom'
require! './footprints'
require! './netlist'
require! './guide'
require! './schema-manager': {SchemaManager}
require! '../text2arr': {text2arr}


# Recursively walk through links
get-net = (netlist, id, included=[], mark) ~>
    #console.log "...getting net for #{id}"
    reduced = []
    included.push id
    if find (.remove), netlist[id]
        #console.warn "Netlist(#{id}) is marked to be removed (already merged?)"
        return []
    for netlist[id]
        if ..link
            # follow the link
            unless ..target in included
                linked = get-net netlist, ..target, included, {+remove}
                for linked
                    unless ..uname in reduced
                        reduced.push ..
                    else
                        console.warn "Skipping duplicate pads from linked net"
        else
            reduced ++= ..pads
    if mark
        # do not include this net in further lookups
        netlist[id].push mark
    reduced

the-one-in = (arr) ->
    # expect only one truthy value in the array
    # and return it
    the-only-value = null
    for id in arr
        id = parse-int id 
        if id 
            unless the-only-value
                the-only-value = id
            else if "#{id}" isnt "#{the-only-value}"
                console.error "the-one-in: ", arr
                throw new Error "We have multiple values in this array"
    the-only-value

prefix-value = (o, pfx) ->
    res = {}
    for k, v of o 
        if typeof! v is \Object 
            v2 = prefix-value v, pfx
            res[k] = v2 
        else 
            res[k] = text2arr v .map ((x) -> "#{pfx}#{x}")
    return res 


export class Schema implements bom, footprints, netlist, guide
    (opts) ->
        '''
        opts:
            name: Name of schema
            prefix: *Optional* Prefix of components
            data: (see docs/schema-usage.md)
        '''
        unless opts
            throw new Error "Data should be provided on init."

        @name = opts.schema-name or opts.name or "main"
        @data = if typeof! opts.data is \Function 
            opts.data(opts.value) 
        else 
            opts.data 
            
        @data.bom `merge` (opts.bom or {})

        @prefix = opts.prefix or ''
        @parent = opts.parent
        @scope = new PaperDraw
        @manager = new SchemaManager
            ..register this
        @compiled = false
        @connection-list = {}           # key: trace-id, value: array of related Pads
        @sub-circuits = {}              # TODO: DOCUMENT THIS

        @netlist = []                   # array of "array of `Pad` objects (aeobj) on the same net"
        @_netlist = {}                  # cached and post-processed version of original .netlist {CONN_ID: [pad_names...]}

        @_labels = opts.labels
        @_cables = @data.cables or {}
        @_cables_connected = []         # Virtual connections

        @_iface = []                  # array of interface pins

        # -----------------------------------------------------------
        # Post process the netlist 
        # -----------------------------------------------------------
        # Check for netlist errors 
        data-netlist = flatten-obj @data.netlist 
        for conn, net of data-netlist
            for comp in text2arr net 
                if comp.match /([^.]+)\.$/
                    throw new Error "Netlist Error: Empty pins are not allowed. 
                        Check \"#{comp}\" pin at netlist[\"#{conn}\"] connection."
        # Build interface
        for text2arr @data.iface
            if ..match /([^.]+)\.(.+)/
                # {{COMPONENT}}.{{PIN}} syntax 
                pad = that.0 # pad is {{COMPONENT}}.{{PIN}}
                component = that.1
                pin = that.2

                # Expose this pin as an interface
                @_iface.push pin 

                # connect the interface pin to the corresponding net  
                @data.netlist["__iface_#{pad}__"] = [pin, pad]
            else 
                @_iface.push .. 

        # if labels are declared, replace @_iface with @_labels 
        if @_labels? 
            for orig-iface, new-label of @_labels 
                @data.netlist[]["__iface_#{orig-iface}__"]
                    ..push orig-iface
                    ..push new-label 
            @_iface = values @_labels 

        # Reduce netlist
        :outer for connection-name, _net of data-netlist
            net = text2arr _net
            # check if we have an indirectly connected net 
            for _c, _n of @_netlist
                if not empty intersection ([_c] ++ _n), ([connection-name] ++ net)
                    # we have such a net already, merge into it
                    @_netlist[_c] = (@_netlist[_c] ++ [connection-name] ++ net)
                        |> reject (.starts-with '__iface_')     # virtual interface entries 
                        |> reject (.match /^[0-9]+\..*$/)
                        |> unique
                    continue outer 

            @_netlist[connection-name] = net

    external-components: ~
        # Current schema's external components
        -> [.. for values @bom when ..data]

    flatten-netlist: ~
        ->
            netlist = @_netlist

            # unconnected interface pins will be treated as null nets
            for @iface
                unless .. of netlist
                    netlist[..] = []

            for circuit-name, circuit of @sub-circuits
                #console.log "adding sub-circuit #{circuit-name} to netlist:", circuit
                for trace-id, net of circuit.flatten-netlist
                    prefixed = "#{circuit-name}.#{trace-id}"
                    #console.log "...added #{trace-id} as #{prefixed}: ", net
                    netlist[prefixed] = net .map (-> "#{circuit-name}.#{it}")

                for circuit.iface
                    # interfaces are null nets
                    prefixed = "#{circuit-name}.#{..}"
                    unless prefixed of netlist
                        netlist[prefixed] = []
            #console.log "FLATTEN NETLIST: ", netlist
            netlist

    components-by-name: ~
        ->
            unless @_components_by_name
                # fill the cache
                @_components_by_name = {}
                for @components
                    if ..component 
                        @_components_by_name[..component.name] = ..component
                    else 
                        console.error "No component object was found:", ..
            return @_components_by_name

    is-link: (name) ->
        if name of @flatten-netlist
            yes
        else
            no

    iface: ~
        -> @_iface
            
    no-connect: ~
        -> text2arr @data.no-connect

    get-pad-from-pin: (pin-name) -> 
        [_, component, pin] = pin-name.match /^([^.]+)\.(.+)$/
        try
            @components-by-name["#{@prefix}#{component}"].get({pin})
        catch 
            debugger 
            throw e 

    compile: !->
        @compiled = true

        # Compile sub-circuits first
        for sch in values @get-bom! when sch.data
            #console.log "Initializing sub-circuit: #{sch.name} ", sch
            @sub-circuits[sch.name] = new Schema sch
                ..compile!

        # add needed footprints
        @add-footprints!

        # Component list is created at this moment. 
        # Process the `cables` property. 
        cable-connections = []
        for i, j of @_cables 
            connection = text2arr j
                ..push i 
            # if this is a simple pin-to-pin connection, just append it
            if or-list connection.map (.match /^[a-zA-Z_][^.]*\.[^.]+$/)
                cable-connections.push connection 
            else 
                # this is a connector match
                _connectors = connection.map (~> @components-by-name[it])
                _reference_conn = _connectors.shift!
                for _connectors
                    if Object.keys(..iface).length isnt Object.keys(_reference_conn.iface).length
                            throw new Error "Pin counts of cable interfaces do not match: #{..name} and #{_reference_conn.name}" 

                for pin-num, pin-name of _reference_conn.iface
                    _connection = ["#{_reference_conn.name}.#{pin-name}"]
                    for conn in _connectors
                        _connection.push "#{conn.name}.#{conn.iface[pin-num]}"
                    cable-connections.push _connection

        for jumpers in cable-connections
            injection-point = null 
            for k, net of @_netlist
                unless empty intersection ([k] ++ net), jumpers 
                    unless injection-point?
                        injection-point = k 
                        @_netlist[k] = unique (net ++ jumpers)
                        @_cables_connected.push flatten jumpers.map(~> @get-pad-from-pin it) 
                    else
                        # cables are already injected, "re-reduce" the netlist
                        @_netlist[injection-point] = unique (@_netlist[injection-point] ++ @_netlist[k] ++ [k])
                        delete @_netlist[k]

        # Detect unconnected pins and false unused pins
        @find-unused @bom

        # compile netlist
        # -----------------
        netlist = {}
        #console.log "* Compiling schema: #{@name}"
        for id, conn-list of @flatten-netlist
            # TODO: performance improvement:
            # use find-comp for each component only one time
            net = [] # cache (list of connected nodes)
            for full-name in conn-list
                {name, pin, link, raw} = parse-name full-name, do
                    prefix: @prefix
                    external: @external-components
                #console.log "Searching for entity: #{name} and pin: #{pin}, pfx: #{@prefix}"
                if @is-link full-name
                    # Merge into parent net
                    # IMPORTANT: Links must be key of netlist in order to prevent accidental namings
                    #console.warn "HANDLE LINK: #{full-name}"
                    net.push {link: yes, target: full-name}

                    # create a cross link
                    unless full-name of netlist
                        netlist[full-name] = []
                    netlist[full-name].push {link: yes, target: id, type: \cross-link}
                    continue
                else
                    comp = @components-by-name[name]
                    unless comp
                        if name in @iface
                            console.log "Found an interface handle: #{name}. Silently skipping."
                            continue
                        else if name of @data.netlist
                            # This is a connection name, silently skip it 
                            continue
                        else
                            console.error "Current components: ", @components-by-name
                            console.warn "Current netlist: ", @flatten-netlist
                            throw new Error "No such component found: '#{name}' (full name: #{full-name}), pfx: #{@prefix}"

                    pads = (comp.get {pin}) or []
                    if empty pads
                        if comp.type not in flatten [[..type, ..component.type] for @get-upgrades!]
                            console.error "Current iface:", comp, comp.iface
                            err = "No such pin found: '#{pin}' of '#{name}'"
                            console.error err 
                            throw new Error  "#{err} (check the console output)"

                    uses-quick-labels = @bom[(full-name.replace /\..+/, '')].labels?

                    unless comp.allow-duplicate-labels or uses-quick-labels
                        if pads.length > 1
                            if comp.type not in [..type for @get-upgrades!]
                                throw new Error "Multiple pins found: '#{pin}' of '#{name}' (#{comp.type}) in #{@name}"

                    # find duplicate pads (shouldn't be)
                    if (unique-by (.uname), pads).length isnt pads.length
                        console.info "INFO: FOUND DUPLICATE PADS in ", name

                    net.push {name, pads}
            unless id of netlist
                netlist[id] = []
            netlist[id] ++= net  # it might be already created by cross-link

        unless @parent
            #console.log "Flatten netlist:", @flatten-netlist
            #console.log "Netlist (raw) (includes links and cross-links): ", netlist

            # Create the cleaned up @netlist (arrays of arrays of Pad objects)
            @netlist.length = 0
            for id of netlist
                net = get-net netlist, id
                unless empty net
                    @netlist.push net

            # build the @connection-list
            @build-connection-list!

            # Check errors
            @post-check!

            # Output the generated report
            #console.log "... Schema: #{@name}, Connection list:", @connection-list
            #console.log "... Schema: #{@name}, Netlist:", @netlist

    get-required-pads: ->
        all-pads = {}
        for @components
            # request all connectable pads from components
            for ..component.get {+connectable}
                all-pads[..pin] = null
        return all-pads

    build-connection-list: !->
        # Re/Build the connection name table for the net
        # ------------------------------------------------
        # see docs/Schema.md/Schema.connection-list for documentation.
        #
        @connection-list = {}
        # Collect already assigned netid's

        # double-check the @netlist. it shouldn't contain same uname in different nets:
        # TODO: Remove this precaution on v1.0
        _used_uname = []
        for net in @netlist
            for pad in unique-by (.uname), net
                if pad.uname in _used_uname
                    console.warn "Problematic Netlist is: ", @netlist
                    console.warn "...Nets: ", [..map((.uname)) for @netlist when pad.uname in ..map((.uname))]
                    throw "This pad appears (#{pad.uname}) on another net.
                        Is 'tests/simple/indirect connection' test passing?"
                else
                    _used_uname.push pad.uname
        # end of double check

        newly-created = []
        for net in @netlist
            try
                existing-netid = '' + the-one-in [pad.netid for pad in net]
            catch
                # error if there are conflicting netid's already existing
                dump = "#{net.map ((p) -> "#{p.uname}[#{p.netid}]") .join ', '}"
                console.error dump
                throw new Error "Multiple netid's assigned to the pads in the same net (#{unique compact [pad.netid for pad in net] .join ','}): (format: pin-name(pin-no)[netid] ) \n\n #{dump}"

            # use existing netid extracted from one of the pads
            if existing-netid?.match /[0-9]+/
                if existing-netid of @connection-list and "duplicate-netid" not in text2arr @data.disable-drc
                    # this netid seems already occupied.
                    existing = @connection-list[existing-netid].map (.uname) .join ', '
                    curr = net.map (.uname) .join ', '
                    throw new Error "Duplicate netid found: #{existing-netid} (
                        #{curr} already occupied by #{existing}"
                else
                    # create the connection list with that existing netid
                    @connection-list[existing-netid] = net
                    # Propagate existing-netid to all pads in the same net
                    for pad in net
                        pad.netid = existing-netid
            else
                # this net is newly created, take your note to assign
                # next possible netid.
                newly-created.push net

        # Assign newly created net's netid's
        for til newly-created.length
            net = newly-created.pop!
            # generate the next netid
            netid = next-id @connection-list
            @connection-list[netid] = net
            for pad in net
                pad.netid = netid

    connection-list-txt: ~
        # For debugging purposes
        -> 
            txt = {}
            # For debugging purposes
            for netid, net of @connection-list
                for pad in net when not pad.is-via
                    txt[][netid].push pad.uname
            return txt

    netlist_txt: ~
        -> 
            netlist-txt = []
            for net in @netlist
                netlist-txt.push net.map (.uname)
            return netlist-txt

    connection-states-reduced: ~
        -> 
            out = {}
            for netid, state of @_connection_states
                if state.reduced.length > 1 
                    out[netid] = state.reduced
                else 
                    out[netid] = state.reduced.0
            out

    post-check: ->
        # Error report (will stay while aeCAD is in Alpha stage)
        for index, pads of @netlist
            # Check for duplicate pads in the same net
            for _i1, p1 of pads
                for _i2, p2 of pads when _i2 > _i1
                    if p1.uname and p2.uname and p1.uname is p2.uname
                        console.error "Duplicate pads found: #{p1.cid} and #{p2.cid}: in #{_i1} and #{_i2} ", p1.uname, p1

            # Find unmerged nets
            for _i, _pads of @netlist when _i > index
                for p1 in pads
                    for p2 in _pads
                        if p1.uname is p2.uname
                            console.error "Unmerged nets found
                            : Netlist(#{index}) and Netlist(#{_i}) both contains #{p1.uname}"
