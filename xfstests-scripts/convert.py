import xml.etree.ElementTree as ET
import json
from datetime import datetime
import os
import zipfile
import glob
import argparse
import base64
import uuid

def generate_id():
    u = uuid.uuid4()
    short = base64.urlsafe_b64encode(u.bytes).decode('utf-8')
    return short.rstrip('=')

def parse_xunit_xml(xml_file_path: str, results_dir: str, output_dir: str, prefix: str, output_json: str, testtype, subtype, label) -> str:

    tree = ET.parse(xml_file_path)
    root = tree.getroot()

    # Extracting global run information
    test_type = testtype
    run_id = generate_id()
    #subtype = root.find(".//property[@name='FSTESTSET']").attrib.get('value')
    subtype = subtype
    # kernel_release = root.find(".//property[@name='KERNEL']").attrib.get('value').split()[1]
    kernel_release = root.find(".//property[@name='KERNEL']").attrib.get('value')
    #distro = root.find(".//property[@name='zz_build-distro']").attrib.get('value')

    # Assuming vmlinux_path and config_path are not in XML, setting as empty for now
    environment = {
        "vmlinux_path": "",
        "config_path": "",
        "distro": "sample-distro",
        "kernel_release": kernel_release
    }

    os.makedirs(output_dir, exist_ok=True)

    # Parsing test cases
    tests = dict()
    for testcase in root.findall('testcase'):
        name = testcase.attrib.get('name')
        duration = float(testcase.attrib.get('time', 0))
        has_logs = False

        # Create zip file for logs
        log_prefix = os.path.join(results_dir, name)
        zip_filename = f"{os.path.join(os.getcwd(), output_dir, name.replace('/', '-') + '.zip')}"
        with zipfile.ZipFile(zip_filename, 'w') as zipf:
            print(f"Looking for logs in: {log_prefix}.*")
            print(f"Found files: {glob.glob(f'{log_prefix}.*')}")
            
            for log_file in glob.glob(f"{log_prefix}.*"):
                has_logs = True
                zipf.write(log_file, os.path.basename(log_file))

        # Determine status
        if testcase.find('failure') is not None:
            status = 'fail'
        elif testcase.find('skipped') is not None:
            status = 'skip'
        else:
            status = 'pass'

        # Update status only if it is a fail and not already a fail
        if name in tests:
            if status == 'fail' and tests[name]['status'] != 'fail':
                tests[name]['status'] = status
        else:

            if has_logs:
                log_path = f"{os.path.join(prefix, run_id, name.replace('/', '-') + '.zip')}"
            else:
                log_path = ""

            tests[name] = {
                "name": name,
                "status": status,
                "duration": duration,
                "log": log_path
            }

    test_list = []
    for val in tests.values():
        test_list.append(val)

    # Constructing the final JSON object
    result = {
        "test_types": [
            {
                "type": test_type,
                "subtype": {
                        "name": subtype,
                        "runs": [
                            {
                                # TODO: for now we hardcode label. can be fixed
                                "label": label,
                                "run_id": run_id,
                                "tests": test_list,
                                "environment": environment
                            }
                        ]
                    }
            }
        ]
    }

    with open(output_json, "w") as f:
        json.dump(result, f, indent=4)
    print(json.dumps(result, indent=4))

    return run_id

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Parse xUnit XML and generate result JSON.")
    parser.add_argument("xml_path", help="Path to the xUnit results.xml file")
    parser.add_argument("results_dir", help="Directory containing test result data")
    parser.add_argument("output_dir", help="Directory to store logs or output files")
    parser.add_argument("prefix", help="Path prefix were the logs would be stored in dashboard server")
    parser.add_argument("--output_json", help="where to stroe the output json", default="result.json")
    parser.add_argument("--type", help="test type label used in ci-dashboard", default="xfstest")
    parser.add_argument("--subtype", help="test sub-type label used in ci-dashboard", default="ci-yaml")
    parser.add_argument("--label", help="The label for the run", default="<unlabelled>")

    args = parser.parse_args()

    run_id = parse_xunit_xml(args.xml_path, args.results_dir, args.output_dir, args.prefix, args.output_json, args.type, args.subtype, args.label)

    print(f"run id: {run_id}")
