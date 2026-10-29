# csv.jq - CSV text for --csv, from the page's data model (model.json). Usage: jq -j --arg kind inventory|pending -f csv.jq
# Same columns, order and escaping as the page's "Export CSV" buttons (lib/explorer_template.html, csvText()):
#   UTF-8 BOM, CRLF line ends, RFC 4180 quoting (a field with , " CR or LF is wrapped in "..." with "" for ")
#   and a spreadsheet formula guard: a cell starting with = + - @ TAB or CR gets a leading ' (plain numbers are left alone).
def cell: tostring
    | (if test("^[=+\\-@\t\r]") and (test("^-?[0-9]+(\\.[0-9]+)?$") | not) then "'" + . else . end)
    | if test("[\",\r\n]") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
def line: map(cell) | join(",");

if $kind == "inventory" then
    ([.resources[].tags[].k] | unique) as $keys
    | [(.meta.csv_columns.inventory + ($keys | map("tag:" + .)))]
      + [.resources[] | (.tags | map({key: .k, value: .v}) | from_entries) as $t | .csv + [$keys[] | $t[.] // ""]]
else
    [.meta.csv_columns.pending] + [.pending[].csv]
end
| "\ufeff" + (map(line) | join("\r\n")) + "\r\n"
