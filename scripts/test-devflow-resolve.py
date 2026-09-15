import math
import sys
import pytest
from pathlib import Path

# Load devflow_resolve dynamically since it is a script
import importlib.util
spec = importlib.util.spec_from_file_location("devflow_resolve", Path(__file__).parent / "devflow-resolve.py")
devflow_resolve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(devflow_resolve)
json_safe = devflow_resolve.json_safe

def test_json_safe_scalars():
    assert json_safe("string") is True
    assert json_safe(1) is True
    assert json_safe(1.5) is True
    assert json_safe(True) is True
    assert json_safe(False) is True
    assert json_safe(None) is True

def test_json_safe_floats():
    assert json_safe(math.inf) is False
    assert json_safe(-math.inf) is False
    assert json_safe(math.nan) is False

def test_json_safe_collections():
    assert json_safe([1, 2, "three", None]) is True
    assert json_safe({"a": 1, "b": [2, 3], "c": {"d": 4}}) is True

def test_json_safe_invalid_collections():
    assert json_safe([1, math.inf]) is False
    assert json_safe({1: "a"}) is False # non-string key
    assert json_safe({"a": math.inf}) is False
    assert json_safe([1, [2, math.nan]]) is False
    assert json_safe({"a": [1, 2, object()]}) is False

def test_json_safe_unsafe_types():
    assert json_safe((1, 2)) is False
    assert json_safe(set([1, 2])) is False
    assert json_safe(object()) is False

    class Custom:
        pass
    assert json_safe(Custom()) is False

if __name__ == "__main__":
    sys.exit(pytest.main([__file__]))
