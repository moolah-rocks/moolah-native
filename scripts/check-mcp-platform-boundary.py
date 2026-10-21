#!/usr/bin/env python3
"""Check generated target membership, including macOS-only hosting dependencies."""
import json
import subprocess

project = json.loads(subprocess.check_output([
    "plutil", "-convert", "json", "-o", "-", "Moolah.xcodeproj/project.pbxproj"
]))["objects"]
for target in project.values():
    if target.get("isa") != "PBXNativeTarget":
        continue
    name = target["name"]
    products = {
        project[ref]["productName"]
        for ref in target.get("packageProductDependencies", [])
    }
    if name == "Moolah_macOS":
        assert "MoolahMCP" in products, "macOS must link MoolahMCP"
    elif "iOS" in name:
        assert not products & {"MoolahMCP", "MCP", "Hummingbird"}, products
        for phase_id in target["buildPhases"]:
            phase = project[phase_id]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for build_id in phase["files"]:
                file = project[project[build_id]["fileRef"]]
                path = file.get("path", "")
                assert "MCP" not in path, f"{name} compiles {path}"
print("MCP hosting is exclusive to macOS targets.")
