"""Daily order stream for the simulated food-delivery platform.

Orders for a date are generated from a seed derived from that date, so the same
date always yields exactly the same orders. Patterns modelled:

* lunch (12-14h) and dinner (19-22h) peaks, more orders on Friday-Sunday and
  ~15% year-on-year growth;
* customers order from restaurants and riders in their own city, and a heavy
  tail of frequent customers produces realistic repeat-customer rates;
* ~5% cancellations, ~2% refunds, free delivery above Rs 499, capped discounts;
* delivery times rise at peak hours, so some orders breach the 45-minute SLA,
  and late orders get lower ratings.

About 2.5-3% of orders carry deliberate defects for cleansing/DQ to catch:
blank customer_id, negative gross amount, impossible timestamps, inconsistent
status spelling, a zero item quantity, and duplicated order records.
"""

import copy
import random
from datetime import date, datetime, time
from typing import Any

from src.generator.master_data import Customer, DeliveryPartner, MenuItem, Platform, Restaurant
from src.config import CALENDAR_START
from src.generator.reference_data import SEED

BASE_DAILY_ORDERS = 180
YEARLY_GROWTH = 0.15
WEEKDAY_FACTOR = (1.0, 0.95, 0.95, 1.0, 1.15, 1.35, 1.30)  # Monday .. Sunday

# Relative order volume per hour of day (lunch and dinner peaks)
HOURLY_WEIGHTS = (1, 0, 0, 0, 0, 0, 1, 2, 3, 3, 4, 6, 12, 14, 10, 5, 4, 5, 7, 12, 15, 14, 9, 4)
PEAK_HOURS = frozenset({12, 13, 14, 19, 20, 21, 22})

FREE_DELIVERY_THRESHOLD = 499
MAX_DISCOUNT = 150
SLA_MINUTES = 45

STATUS_WEIGHTS = {"Delivered": 93, "Cancelled": 5, "Refunded": 2}
MESSY_STATUS_SPELLINGS = {
    "Delivered": ("delivered", " DELIVERED", "Delivered "),
    "Cancelled": ("Canceled", "cancelled ", "CANCELLED"),
    "Refunded": ("refunded", "REFUNDED "),
}
PAYMENT_WEIGHTS = {"PM_UPI": 52, "PM_CC": 14, "PM_DC": 10, "PM_NB": 4, "PM_COD": 12, "PM_WALLET": 8}

# Cumulative thresholds for one defect per order (mutually exclusive), plus duplicates
DEFECT_BLANK_CUSTOMER = 0.006
DEFECT_NEGATIVE_AMOUNT = 0.011
DEFECT_BAD_TIMESTAMP = 0.015
DEFECT_MESSY_STATUS = 0.020
DEFECT_ZERO_QUANTITY = 0.023
DUPLICATE_ORDER_RATE = 0.006


def daily_order_volume(order_date: date, rng: random.Random) -> int:
    """Number of orders for the day: growth trend x weekday pattern x noise."""
    years_elapsed = (order_date - CALENDAR_START).days / 365.25
    volume = (BASE_DAILY_ORDERS * (1 + YEARLY_GROWTH) ** years_elapsed
              * WEEKDAY_FACTOR[order_date.weekday()] * rng.uniform(0.92, 1.08))
    return int(volume)


def _delivery_minutes(rng: random.Random, hour: int, weekend: bool) -> int:
    mean = 31 + (7 if hour in PEAK_HOURS else 0) + (3 if weekend else 0)
    return max(12, min(95, round(rng.gauss(mean, 9))))


def _rating(rng: random.Random, status: str, minutes: int | None) -> int | None:
    if status == "Cancelled":
        return None
    if status == "Refunded":
        return rng.choice((1, 2, None))
    if rng.random() < 0.15:  # many customers never rate
        return None
    weights = (10, 20, 35, 25, 10) if minutes > SLA_MINUTES else (2, 4, 14, 40, 40)
    return rng.choices((1, 2, 3, 4, 5), weights)[0]


def _payment_method(rng: random.Random, net_amount: float) -> str:
    weights = dict(PAYMENT_WEIGHTS)
    if net_amount > 1200:
        weights["PM_COD"] = 3  # fewer cash payments on large orders
    return rng.choices(list(weights), list(weights.values()))[0]


def _build_order(rng: random.Random, order_id: str, order_date: date, customer: Customer,
                 restaurant: Restaurant, partner: DeliveryPartner, menu: list[MenuItem]) -> dict[str, Any]:
    hour = rng.choices(range(24), HOURLY_WEIGHTS)[0]
    ordered_at = datetime.combine(order_date, time(hour, rng.randint(0, 59), rng.randint(0, 59)))

    dishes = rng.sample(menu, k=min(len(menu), rng.choices((1, 2, 3, 4), (35, 35, 20, 10))[0]))
    items = [{"item_id": dish.item_id,
              "quantity": rng.choices((1, 2, 3), (75, 18, 7))[0],
              "unit_price": float(dish.price_on(order_date))} for dish in dishes]
    gross = round(sum(i["quantity"] * i["unit_price"] for i in items), 2)

    discount = 0.0
    if rng.random() < 0.45:
        discount = min(round(gross * rng.choice((0.10, 0.15, 0.20, 0.25)), 2), MAX_DISCOUNT)
    delivery_fee = 0.0 if gross >= FREE_DELIVERY_THRESHOLD else float(rng.choice((25, 35, 45)))
    net = round(gross - discount + delivery_fee, 2)

    status = rng.choices(list(STATUS_WEIGHTS), list(STATUS_WEIGHTS.values()))[0]
    minutes = None if status == "Cancelled" else _delivery_minutes(rng, hour, order_date.weekday() >= 5)

    return {
        "order_id": order_id,
        "customer_id": customer.customer_id,
        "restaurant_id": restaurant.restaurant_id,
        "delivery_partner_id": partner.partner_id,
        "payment_method_id": _payment_method(rng, net),
        "order_datetime": ordered_at.strftime("%Y-%m-%d %H:%M:%S"),
        "gross_amount": gross,
        "discount": discount,
        "delivery_fee": delivery_fee,
        "net_amount": net,
        "delivery_minutes": minutes,
        "rating": _rating(rng, status, minutes),
        "order_status": status,
        "items": items,
    }


def _inject_defects(orders: list[dict[str, Any]], rng: random.Random) -> list[dict[str, Any]]:
    """Corrupt a small, seeded share of orders and duplicate a few."""
    result = []
    for order in orders:
        roll = rng.random()
        if roll < DEFECT_BLANK_CUSTOMER:
            order["customer_id"] = ""
        elif roll < DEFECT_NEGATIVE_AMOUNT:
            order["gross_amount"] = -order["gross_amount"]
        elif roll < DEFECT_BAD_TIMESTAMP:
            day = order["order_datetime"][:10]
            order["order_datetime"] = rng.choice((f"{day} 25:61:00", f"{day[:8]}32 12:00:00", day.replace("-", "/")))
        elif roll < DEFECT_MESSY_STATUS:
            order["order_status"] = rng.choice(MESSY_STATUS_SPELLINGS[order["order_status"]])
        elif roll < DEFECT_ZERO_QUANTITY:
            order["items"][0]["quantity"] = 0
        result.append(order)
        if rng.random() < DUPLICATE_ORDER_RATE:
            result.append(copy.deepcopy(order))
    return result


def generate_orders(order_date: date, platform: Platform) -> list[dict[str, Any]]:
    """All orders placed on `order_date`, each with its nested order items.

    Deterministic: the same date always returns the same orders.
    """
    rng = random.Random(f"{SEED}:orders:{order_date.isoformat()}")

    customers = [c for c in platform.customers if c.signup_date <= order_date]
    customer_weights = [c.order_weight for c in customers]
    restaurants_by_city: dict[str, list[Restaurant]] = {}
    for r in platform.restaurants:
        if r.is_active_on(order_date):
            restaurants_by_city.setdefault(r.city.name, []).append(r)
    partners_by_city: dict[str, list[DeliveryPartner]] = {}
    for p in platform.partners:
        if p.status == "ACTIVE" and p.joined_date <= order_date:
            partners_by_city.setdefault(p.city.name, []).append(p)

    orders = []
    stamp = order_date.strftime("%Y%m%d")
    for n in range(1, daily_order_volume(order_date, rng) + 1):
        customer = rng.choices(customers, customer_weights)[0]
        city = customer.location_on(order_date)[0].name
        local_restaurants = restaurants_by_city[city]
        restaurant = rng.choices(local_restaurants, [r.popularity for r in local_restaurants])[0]
        menu = [m for m in platform.menus_by_restaurant[restaurant.restaurant_id] if m.is_available]
        menu = menu or list(platform.menus_by_restaurant[restaurant.restaurant_id])
        partner = rng.choice(partners_by_city[city])
        orders.append(_build_order(rng, f"ORD_{stamp}_{n:05d}", order_date, customer, restaurant, partner, menu))

    defect_rng = random.Random(f"{SEED}:order-defects:{order_date.isoformat()}")
    return _inject_defects(orders, defect_rng)
