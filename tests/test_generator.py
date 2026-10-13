"""Synthetic source data: determinism, realism and the injected dirty-data rate."""

from collections import Counter
from datetime import date, timedelta

import pytest

from src.generator.master_data import build_platform, snapshot_rows
from src.generator.orders import generate_orders

DAY = date(2026, 3, 2)
VALID_STATUSES = {"Delivered", "Cancelled", "Refunded"}


@pytest.fixture(scope="module")
def platform():
    return build_platform()


@pytest.fixture(scope="module")
def ten_days_of_orders(platform):
    return [order for offset in range(10) for order in generate_orders(DAY + timedelta(days=offset), platform)]


def _is_clean(order) -> bool:
    return (order["customer_id"] != "" and order["gross_amount"] > 0
            and order["order_status"] in VALID_STATUSES and all(i["quantity"] > 0 for i in order["items"])
            and len(order["order_datetime"]) == 19 and order["order_datetime"][11:13] < "24"
            and order["order_datetime"][8:10] <= "31")


def test_same_date_always_produces_identical_data(platform):
    assert generate_orders(DAY, platform) == generate_orders(DAY, platform)
    assert snapshot_rows(platform, DAY) == snapshot_rows(platform, DAY)


def test_dirty_data_rate_is_around_two_to_three_percent(ten_days_of_orders):
    order_ids = Counter(o["order_id"] for o in ten_days_of_orders)
    duplicates = sum(count - 1 for count in order_ids.values())
    defective = sum(not _is_clean(o) for o in ten_days_of_orders) + duplicates
    assert 0.015 <= defective / len(ten_days_of_orders) <= 0.045


def test_cancellation_rate_is_about_five_percent(ten_days_of_orders):
    cancelled = sum(o["order_status"].strip().lower() in ("cancelled", "canceled") for o in ten_days_of_orders)
    assert 0.03 <= cancelled / len(ten_days_of_orders) <= 0.08


def test_clean_orders_follow_business_rules(ten_days_of_orders):
    for order in filter(_is_clean, ten_days_of_orders):
        items_total = sum(i["quantity"] * i["unit_price"] for i in order["items"])
        assert order["gross_amount"] == pytest.approx(items_total)
        assert order["net_amount"] == pytest.approx(order["gross_amount"] - order["discount"] + order["delivery_fee"])
        if order["order_status"] == "Cancelled":
            assert order["delivery_minutes"] is None and order["rating"] is None


def test_orders_reference_customers_and_restaurants_valid_on_that_day(platform):
    customers = {c.customer_id: c for c in platform.customers}
    restaurants = {r.restaurant_id: r for r in platform.restaurants}
    for order in generate_orders(DAY, platform):
        restaurant = restaurants[order["restaurant_id"]]
        assert restaurant.is_active_on(DAY)
        if order["customer_id"]:
            customer = customers[order["customer_id"]]
            assert customer.signup_date <= DAY
            assert customer.location_on(DAY)[0] == restaurant.city  # customers order locally


def test_weekends_are_busier_than_weekdays(platform):
    monday, saturday = date(2026, 10, 12), date(2026, 10, 17)
    assert len(generate_orders(saturday, platform)) > len(generate_orders(monday, platform))


def test_value_changing_defects_belong_to_fixed_entities(platform):
    """An invalid pincode must not come and go at random, or cleansing would create false SCD2 versions."""
    defective = {c.customer_id for c in platform.customers if c.home_pincode == "INVALID_PIN"}
    for day in (DAY, DAY + timedelta(days=30)):
        flagged = {row["customer_id"] for row in snapshot_rows(platform, day)["customers"]
                   if row["pincode"] == "INVALID_PIN"}
        assert flagged and flagged <= defective
