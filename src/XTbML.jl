

function open_and_read(path)
    s = open(path) do file
        read(file, String)
    end
end

function getXML(open_file)

    return xml = XMLDict.xml_dict(open_file)

end

# get potentially missing value out of dict
function get_and_parse(dict, key)
    try
        return val = Parsers.parse(Float64, dict[key])
    catch y
        if isa(y, KeyError)
            return val = missing
        else
            throw(y)
        end
    end
end

struct XTbMLTable{S,U}
    select::S
    ultimate::U
    d::TableMetaData
end

function parseXTbMLTable(x, path)
    md = x["XTbML"]["ContentClassification"]
    name = get(md, "TableName", nothing) |> strip
    content_type = get(get(md, "ContentType", nothing), "", nothing) |> strip
    id = get(md, "TableIdentity", nothing) |> strip
    provider = get(md, "ProviderName", nothing) |> strip
    reference = get(md, "TableReference", nothing) |> strip
    description = get(md, "TableDescription", nothing) |> strip
    comments = get(md, "Comments", nothing) |> strip
    source_path = path
    d = TableMetaData(
        name=name,
        id=id,
        provider=provider,
        reference=reference,
        content_type=content_type,
        description=description,
        comments=comments,
        source_path=source_path,
    )

    if isa(x["XTbML"]["Table"], Vector)
        # for a select and ultimate table, will have multiple tables
        # parsed into a vector of tables
        sel = map(x["XTbML"]["Table"][1]["Values"]["Axis"]) do ai
            (issue_age = Parsers.parse(Int, ai[:t]),
                rates = [(duration = Parsers.parse(Int, aj[:t]), rate = get_and_parse(aj, "")) for aj in ai["Axis"]["Y"] if !ismissing(get_and_parse(aj, ""))])
        end

        ult = map(x["XTbML"]["Table"][2]["Values"]["Axis"]["Y"]) do ai 
            (age  = Parsers.parse(Int, ai[:t]), rate = get_and_parse(ai, ""),)
        end

    else
        # a table without select period will just have one set of values

        ult = map(x["XTbML"]["Table"]["Values"]["Axis"]["Y"]) do ai
            (age = Parsers.parse(Int, ai[:t]), 
                rate = get_and_parse(ai, ""))
        end

        sel = nothing

    end

    tbl = XTbMLTable(
        sel,
        ult,
        d
    )

    return tbl
end

function XTbML_Table_To_MortalityTable(tbl::XTbMLTable)
    ult = UltimateMortality(
                [v.rate for v in  tbl.ultimate], 
                start_age=tbl.ultimate[1].age
            )

    ult_omega = lastindex(ult)

    if !isnothing(tbl.select)
        sel =   map(tbl.select) do (issue_age, rates)
            last_sel_age = issue_age + rates[end].duration - 1
            first_defined_select_age =  issue_age + rates[1].duration - 1
            last_age = max(last_sel_age, ult_omega)
            vec = map(issue_age:last_age) do attained_age
                if attained_age < first_defined_select_age
                    return missing
                else
                    if attained_age <= last_sel_age
                        return rates[attained_age - first_defined_select_age + 1].rate
                    else
                        return ult[attained_age]
                    end
                end
            end 
            return mortality_vector(vec, start_age=issue_age)
        end
        sel = OffsetArray(sel, tbl.select[1].issue_age - 1)

        return MortalityTable(sel, ult, metadata=tbl.d)
    else
        return MortalityTable(ult, metadata=tbl.d)
    end
end

"""
    readXTbML(path)

    Loads the [XtbML](https://mort.soa.org/About.aspx) (the SOA XML data format for mortality tables) stored at the given path and returns a `MortalityTable`.
"""
function readXTbML(path)
    path
    x = open_and_read(path) |> getXML
    XTbML_Table_To_MortalityTable(parseXTbMLTable(x, path))
end


# Load Available Tables ###

"""
    tables(dir=nothing)

Loads the [XtbML](https://mort.soa.org/About.aspx) (the SOA XML data format for mortality tables) stored in the given path. If no path is specified, will load the packages in the MortalityTables package directory. To see where your system keeps packages, run `DEPOT_PATH` from a Julia REPL.
"""
function tables(dir=nothing)
    if isnothing(dir)
        table_dir = joinpath(pkgdir(MortalityTables), "src", "tables", "SOA")
    else
        table_dir = dir
    end
    tables = []
    @info "Loading built-in Mortality Tables..."
    for (root, dirs, files) in walkdir(table_dir)
        transducer = opcompose(Filter(x -> basename(x)[end - 3:end] == ".xml"), Map(x -> readXTbML(joinpath(root, x))))
        tables = files |> transducer |> tcopy
    end
    # return tables
    return Dict(tbl.metadata.name => tbl for tbl in tables if ~isnothing(tbl))
end