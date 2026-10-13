"""Order and Order Items Data Generator.
Simulates real-world food aggregator order stream with lunch/dinner peaks,
weekend spikes, delivery durations, cancellation rates, and 2-3% injected dirty data.
"""

import json
import random
from datetime import datetime, time, timedelta
from pathlib import Path
from typing import List, Dict, Any, Tuple, Optional
from src.config import DATA_LANDING_DIR
from src.utils.logger import get_logger

logger = get_logger("src.generator.orders")

# Re-use seed for stability
random.seed(42)

def _generate_time_with_peaks() -> time:
    """Simulates realistic delivery order times with lunch and dinner peaks."""
    # Probabilistic hourly weights
    # 00-11: 5%, 12-15: 35% (Lunch), 15-18: 15% (Snacks), 19-23: 45% (Dinner)
    hour_buckets = (
        [random.randint(0, 11) for _ in range(5)] +
        [random.randint(12, 14) for _ in range(35)] +
        [random.randint(15, 18) for _ in range(15)] +
        [random.randint(19, 23) for _ in range(45)]
    )
    hour = random.choice(hour_buckets)
    minute = random.randint(0, 59)
    second = random.randint(0, 59)
    return time(hour, minute, second)

def generate_daily_orders(
    target_date: str,
    customers: List[Dict[str, Any]],
    restaurants: List[Dict[str, Any]],
    menu_items: List[Dict[str, Any]],
    delivery_partners: List[Dict[str, Any]],
    base_order_count: int = 200
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Generates orders and line items for a specific date.
    
    Args:
        target_date: Date string in 'YYYY-MM-DD' format.
        customers: Master customers list.
        restaurants: Master restaurants list.
        menu_items: Master menu catalog.
        delivery_partners: Delivery partners fleet.
        base_order_count: Base order volume for weekdays.
        
    Returns:
        Tuple of (orders_list, order_items_list).
    """
    dt = datetime.strptime(target_date, "%Y-%m-%d")
    is_weekend = dt.weekday() in (5, 6) # Saturday or Sunday
    order_volume = int(base_order_count * (1.35 if is_weekend else 1.0))

    # Pre-index menu items by restaurant_id
    items_by_rest: Dict[str, List[Dict[str, Any]]] = {}
    for item in menu_items:
        items_by_rest.setdefault(item["restaurant_id"], []).append(item)

    payment_method_ids = ["PM_UPI", "PM_CC", "PM_DC", "PM_NB", "PM_COD", "PM_WALLET"]
    pm_weights = [0.55, 0.15, 0.10, 0.05, 0.10, 0.05]

    orders: List[Dict[str, Any]] = []
    order_items: List[Dict[str, Any]] = []

    date_str_slug = dt.strftime("%Y%m%d")

    for i in range(1, order_volume + 1):
        order_num = f"ORD_{date_str_slug}_{i:04d}"
        cust = random.choice(customers)
        rest = random.choice(restaurants)
        partner = random.choice(delivery_partners)
        pm_id = random.choices(payment_method_ids, weights=pm_weights)[0]

        order_time = _generate_time_with_peaks()
        order_datetime_str = f"{target_date} {order_time.strftime('%H:%M:%S')}"

        # Select 1 to 4 items from the restaurant
        available_items = items_by_rest.get(rest["restaurant_id"], menu_items[:5])
        num_items = random.randint(1, min(4, len(available_items)))
        chosen_items = random.sample(available_items, num_items)

        gross_amount = 0.0
        current_items = []

        for item in chosen_items:
            qty = random.choices([1, 2, 3], weights=[0.7, 0.2, 0.1])[0]
            unit_price = float(item["base_price"])
            line_total = round(qty * unit_price, 2)
            gross_amount += line_total

            current_items.append({
                "order_id": order_num,
                "item_id": item["item_id"],
                "quantity": qty,
                "unit_price": unit_price
            })

        gross_amount = round(gross_amount, 2)
        # Discount logic (promotions / vouchers)
        discount = round(gross_amount * random.choice([0.0, 0.0, 0.1, 0.15, 0.2]), 2)
        delivery_fee = random.choice([30.0, 40.0, 50.0, 60.0])
        net_amount = round(gross_amount - discount + delivery_fee, 2)

        # Delivery minutes and status
        # ~5% cancellations
        order_status = random.choices(
            ["Delivered", "Cancelled", "Refunded"],
            weights=[0.92, 0.05, 0.03]
        )[0]

        if order_status == "Cancelled":
            delivery_minutes = 0
            rating = None
            is_late = 0
        else:
            delivery_minutes = int(random.gauss(38, 10))
            delivery_minutes = max(18, min(delivery_minutes, 85))
            is_late = 1 if delivery_minutes > 45 else 0
            # Skewed rating 1-5
            rating = random.choices(
                [None, 1.0, 2.0, 3.0, 4.0, 4.5, 5.0],
                weights=[0.08, 0.02, 0.04, 0.10, 0.30, 0.26, 0.20]
            )[0]

        # -------------------------------------------------------------
        # Deliberately Inject 2-3% Dirty Data
        # -------------------------------------------------------------
        customer_id_val = cust["customer_id"]
        order_datetime_val = order_datetime_str
        gross_amount_val = gross_amount

        if i % 45 == 0:
            # Dirty 1: Missing or blank customer_id
            customer_id_val = ""
        elif i % 55 == 0:
            # Dirty 2: Negative gross amount
            gross_amount_val = -120.0
            net_amount = -120.0
        elif i % 70 == 0:
            # Dirty 3: Malformed date string
            order_datetime_val = "2024-02-31 25:99:99"

        order_record = {
            "order_id": order_num,
            "customer_id": customer_id_val,
            "restaurant_id": rest["restaurant_id"],
            "delivery_partner_id": partner["partner_id"],
            "payment_method_id": pm_id,
            "order_datetime": order_datetime_val,
            "gross_amount": gross_amount_val,
            "discount": discount,
            "delivery_fee": delivery_fee,
            "net_amount": net_amount,
            "delivery_minutes": delivery_minutes,
            "rating": rating,
            "order_status": order_status,
            "items": current_items
        }

        orders.append(order_record)
        order_items.extend(current_items)

        # Dirty 4: Duplicate record injection (~1.5%)
        if i % 65 == 0:
            orders.append(order_record.copy())

    logger.info(f"Generated {len(orders)} orders and {len(order_items)} items for date {target_date}")
    return orders, order_items

def save_orders_json(orders: List[Dict[str, Any]], target_date: str, output_dir: Path = DATA_LANDING_DIR) -> Path:
    """Exports orders payload to a JSON landing file."""
    filepath = output_dir / f"orders_{target_date}.json"
    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(orders, f, indent=2, default=str)
    logger.info(f"Saved orders to {filepath}")
    return filepath
