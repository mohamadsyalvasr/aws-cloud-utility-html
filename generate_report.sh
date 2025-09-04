#!/bin/bash
# generate_report.sh
# Generates a single HTML file to view the combined JSON report.

set -euo pipefail

log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# Check if arguments are provided
if [ "$#" -ne 2 ]; then
    log "❌ Usage: $0 <input_json_file> <output_html_file>"
    exit 1
fi

INPUT_JSON="$1"
OUTPUT_HTML="$2"

log "Creating HTML report template..."

cat > "$OUTPUT_HTML" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AWS Inventory Report</title>
    <link rel="stylesheet" type="text/css" href="https://cdn.datatables.net/2.3.3/css/dataTables.dataTables.css">
    <link rel="stylesheet" type="text/css" href="https://cdn.datatables.net/buttons/3.2.0/css/buttons.dataTables.min.css">
    <style>
        body { font-family: sans-serif; padding: 20px; }
        .container { max-width: 1200px; margin: auto; }
        .report-section { margin-bottom: 40px; }
        h1, h2 { text-align: center; color: #333; }
        table.dataTable thead th, table.dataTable thead td { padding: 10px; border-bottom: 1px solid #111; }
        table.dataTable.stripe tbody tr.odd, table.dataTable.display tbody tr.odd { background-color: #f9f9f9; }
        table.dataTable.hover tbody tr:hover { background-color: #f1f1f1; }
        #report-selector { text-align: center; margin-bottom: 20px; }
        #report-selector button {
            padding: 10px 20px;
            font-size: 16px;
            cursor: pointer;
            margin: 5px;
            border: 1px solid #ccc;
            border-radius: 5px;
            background-color: #f0f0f0;
        }
        #report-selector button.active {
            background-color: #007bff;
            color: white;
            border-color: #007bff;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>AWS Inventory Report</h1>
        <div id="report-selector"></div>
        <div id="report-container"></div>
    </div>

    <script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>
    <script src="https://cdn.datatables.net/2.3.3/js/dataTables.min.js"></script>
    <script src="https://cdn.datatables.net/buttons/3.2.0/js/dataTables.buttons.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.1.3/jszip.min.js"></script>
    <script src="https://cdn.datatables.net/buttons/3.2.0/js/buttons.html5.min.js"></script>

    <script>
        $(document).ready(function() {
            var allReportsData;
            var reportSelector = $('#report-selector');
            var reportContainer = $('#report-container');

            // Fetch the JSON data
            $.getJSON("all_reports.json", function(data) {
                allReportsData = data;
                var reportTypes = {};
                
                // Group data by report type
                data.forEach(function(item) {
                    var type = item.reportType;
                    if (!reportTypes[type]) {
                        reportTypes[type] = [];
                    }
                    reportTypes[type].push(item);
                });

                // Create a button for each report type
                for (var type in reportTypes) {
                    if (reportTypes.hasOwnProperty(type)) {
                        var button = $('<button></button>').text(type).attr('data-report', type);
                        reportSelector.append(button);
                    }
                }

                // Show the first report by default
                var firstReportType = Object.keys(reportTypes)[0];
                if (firstReportType) {
                    showReport(firstReportType);
                    reportSelector.find('button[data-report="' + firstReportType + '"]').addClass('active');
                }

                // Handle button clicks
                reportSelector.on('click', 'button', function() {
                    var selectedReportType = $(this).attr('data-report');
                    reportSelector.find('button').removeClass('active');
                    $(this).addClass('active');
                    showReport(selectedReportType);
                });

                function showReport(reportType) {
                    var reportData = reportTypes[reportType];
                    var columnDefinitions = Object.keys(reportData[0] || {}).map(function(key) {
                        return { title: key.replace(/([A-Z])/g, ' $1').replace(/^./, function(str){ return str.toUpperCase(); }), data: key };
                    });

                    // Clear previous report
                    reportContainer.empty();
                    
                    // Create new table
                    var tableId = 'table-' + reportType;
                    var tableHtml = '<div class="report-section"><h2>' + reportType + ' Report</h2><table id="' + tableId + '" class="display"></table></div>';
                    reportContainer.append(tableHtml);

                    // Initialize DataTables with JSON data
                    $('#' + tableId).DataTable({
                        data: reportData,
                        columns: columnDefinitions,
                        dom: 'Bfrtip',
                        buttons: [
                            'copyHtml5',
                            'excelHtml5',
                            'csvHtml5',
                            'pdfHtml5'
                        ],
                        responsive: true
                    });
                }

            }).fail(function(jqXHR, textStatus, errorThrown) {
                reportContainer.html('<div style="text-align:center; color:red;">Failed to load report data. Please ensure "all_reports.json" exists.</div>');
                log("Error loading JSON: " + textStatus + ", " + errorThrown);
            });
        });
    </script>
</body>
</html>
EOF

log "HTML file created successfully at $OUTPUT_HTML"