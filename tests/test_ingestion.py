"""Ingestion: structural validation, raw parsing and file moves (no database needed)."""

import json
from datetime import date

import pytest

from src.ingestion import file_mover
from src.ingestion.parse import parse_file
from src.ingestion.sources import SOURCES
from src.ingestion.validate import ValidationError, validate_file

CUSTOMERS = SOURCES["customers"]
ORDERS = SOURCES["orders"]
CUSTOMER_HEADER = "customer_id,customer_name,email,phone,city,state,pincode,signup_date"


def _order(**overrides):
    order = {"order_id": "ORD_1", "customer_id": "CUST_00001", "restaurant_id": "REST_001",
             "delivery_partner_id": "PART_001", "payment_method_id": "PM_UPI",
             "order_datetime": "2026-03-02 13:05:00", "gross_amount": 450.0, "discount": 0.0,
             "delivery_fee": 35.0, "net_amount": 485.0, "delivery_minutes": 32, "rating": None,
             "order_status": "Delivered",
             "items": [{"item_id": "ITEM_00001", "quantity": 2, "unit_price": 225.0}]}
    order.update(overrides)
    return order


@pytest.fixture
def write(tmp_path):
    def _write(name: str, content: str, encoding: str = "utf-8"):
        path = tmp_path / name
        path.write_text(content, encoding=encoding)
        return path
    return _write


# -- validation --------------------------------------------------------------
def test_valid_csv_passes(write):
    validate_file(write("c.csv", f"{CUSTOMER_HEADER}\nC1,Asha,a@x.in,,Pune,MH,411001,2026-01-01\n"), CUSTOMERS)


def test_csv_saved_by_excel_with_bom_passes(write):
    validate_file(write("c.csv", f"{CUSTOMER_HEADER}\nC1,Asha,,,Pune,MH,,\n", encoding="utf-8-sig"), CUSTOMERS)


@pytest.mark.parametrize("content, message", [
    ("", "empty"),
    (f"{CUSTOMER_HEADER}\n", "no data rows"),
    ("customer_id,full_name\nC1,Asha\n", "missing required columns"),
    (f"{CUSTOMER_HEADER},city\nC1,A,,,P,M,,,P\n", "duplicate column"),
])
def test_invalid_csv_is_rejected(write, content, message):
    with pytest.raises(ValidationError, match=message):
        validate_file(write("c.csv", content), CUSTOMERS)


@pytest.mark.parametrize("payload, message", [
    ({"orders": []}, "JSON array"),
    ([], "empty"),
    ([{"order_id": "ORD_1"}], "missing keys"),
    ([_order(items="none")], "must be an array"),
    ([_order(items=[{"item_id": "ITEM_1"}])], "item missing keys"),
])
def test_invalid_orders_json_is_rejected(write, payload, message):
    with pytest.raises(ValidationError, match=message):
        validate_file(write("o.json", json.dumps(payload)), ORDERS)


def test_malformed_json_is_rejected(write):
    with pytest.raises(ValidationError, match="invalid JSON"):
        validate_file(write("o.json", "[{"), ORDERS)


# -- parsing -----------------------------------------------------------------
def test_csv_values_are_kept_raw_except_empty_becomes_null(write):
    path = write("c.csv", f"{CUSTOMER_HEADER},extra\n C1 ,  Asha Rao  ,,,Pune,MH,INVALID_PIN,2026-01-01,x\n")
    frame = parse_file(path, CUSTOMERS)["stg_customers"]
    row = frame.iloc[0]
    assert list(frame.columns) == CUSTOMER_HEADER.split(",")  # unexpected column dropped
    assert row["customer_name"] == "  Asha Rao  "             # whitespace preserved for cleansing
    assert row["pincode"] == "INVALID_PIN"
    assert row["email"] is None


def test_orders_json_is_flattened_into_orders_and_items(write):
    orders = [_order(), _order(order_id="ORD_2", customer_id="", gross_amount=-120.0,
                               items=[{"item_id": "A", "quantity": 0, "unit_price": 10.0},
                                      {"item_id": "B", "quantity": 1, "unit_price": 20.0}])]
    frames = parse_file(write("o.json", json.dumps(orders)), ORDERS)
    stg_orders, stg_items = frames["stg_orders"], frames["stg_order_items"]
    assert len(stg_orders) == 2 and len(stg_items) == 3
    dirty = stg_orders.set_index("order_id").loc["ORD_2"]
    assert dirty["customer_id"] is None and dirty["gross_amount"] == "-120.0" and dirty["rating"] is None
    assert stg_items[stg_items.item_id == "A"].iloc[0].to_dict() == {
        "order_id": "ORD_2", "item_id": "A", "quantity": "0", "unit_price": "10.0"}


# -- file moves --------------------------------------------------------------
def test_archive_and_quarantine_move_files_by_run_date(tmp_path, monkeypatch, write):
    monkeypatch.setattr(file_mover, "DATA_ARCHIVE_DIR", tmp_path / "archive")
    monkeypatch.setattr(file_mover, "DATA_ERROR_DIR", tmp_path / "error")
    run_date = date(2026, 3, 2)

    archived = file_mover.archive_file(write("good.csv", "x"), run_date)
    rejected = file_mover.quarantine_file(write("bad.csv", ""), run_date, "file is empty")

    assert archived == tmp_path / "archive" / "2026-03-02" / "good.csv" and archived.exists()
    assert rejected.exists() and "file is empty" in rejected.with_name("bad.csv.error.txt").read_text()
    assert not (tmp_path / "good.csv").exists()
