"""Synthetic Master Data Generator for Customers, Restaurants, Menu Items, Partners.
Uses Faker with en_IN locale and fixed random seeds for reproducible data engineering demos.
"""

import csv
import random
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Dict, Any
from faker import Faker
from src.config import DATA_LANDING_DIR
from src.utils.logger import get_logger

logger = get_logger("src.generator.master_data")

# Fixed seed for reproducibility across pipeline runs
RANDOM_SEED = 42
random.seed(RANDOM_SEED)
fake = Faker("en_IN")
Faker.seed(RANDOM_SEED)

# Reference Indian Metros and Major Hubs
INDIAN_CITIES = [
    {"city": "Bengaluru", "state": "Karnataka", "areas": ["Indiranagar", "Koramangala", "HSR Layout", "Whitefield", "Jayanagar"]},
    {"city": "Mumbai", "state": "Maharashtra", "areas": ["Bandra West", "Andheri East", "Powai", "Colaba", "Lower Parel"]},
    {"city": "Delhi NCR", "state": "Delhi", "areas": ["Connaught Place", "Cyber City", "Hauz Khas", "Saket", "Sector 29"]},
    {"city": "Hyderabad", "state": "Telangana", "areas": ["Gachibowli", "Hitec City", "Banjara Hills", "Jubilee Hills", "Madhapur"]},
    {"city": "Chennai", "state": "Tamil Nadu", "areas": ["T. Nagar", "Adyar", "Anna Nagar", "Velachery", "Nungambakkam"]},
    {"city": "Pune", "state": "Maharashtra", "areas": ["Kothrud", "Viman Nagar", "Koregaon Park", "Hinjawadi", "Baner"]},
    {"city": "Kolkata", "state": "West Bengal", "areas": ["Park Street", "Salt Lake", "New Town", "Ballygunge", "Alipore"]}
]

# Cuisine categories & signature menu templates
CUISINE_MENUS = {
    "North Indian": [
        ("Butter Chicken", "Curry", 0, 360),
        ("Paneer Butter Masala", "Curry", 1, 310),
        ("Dal Makhani", "Curry", 1, 260),
        ("Garlic Naan", "Bread", 1, 75),
        ("Tandoori Roti", "Bread", 1, 40),
        ("Chicken Tikka", "Starter", 0, 340)
    ],
    "South Indian": [
        ("Masala Dosa", "Dosa", 1, 140),
        ("Ghee Podi Idli", "Tiffin", 1, 120),
        ("Medu Vada (2 pcs)", "Tiffin", 1, 95),
        ("Filter Coffee", "Beverage", 1, 60),
        ("Onion Rava Dosa", "Dosa", 1, 160),
        ("Chettinad Chicken", "Curry", 0, 380)
    ],
    "Biryani": [
        ("Hyderabadi Chicken Dum Biryani", "Biryani", 0, 340),
        ("Lucknowi Mutton Biryani", "Biryani", 0, 480),
        ("Paneer Subz Biryani", "Biryani", 1, 280),
        ("Mirchi Ka Salan", "Side", 1, 90),
        ("Burani Raita", "Side", 1, 70),
        ("Chicken 65", "Starter", 0, 290)
    ],
    "Chinese": [
        ("Veg Hakka Noodles", "Noodles", 1, 210),
        ("Chicken Fried Rice", "Rice", 0, 240),
        ("Chilli Chicken Gravy", "Main", 0, 320),
        ("Veg Manchurian Dry", "Starter", 1, 250),
        ("Crispy Corn Salt & Pepper", "Starter", 1, 220),
        ("Momos Steamed Chicken (6 pcs)", "Momos", 0, 180)
    ],
    "Fast Food": [
        ("Classic Cheese Burger", "Burger", 1, 160),
        ("Crispy Chicken Burger", "Burger", 0, 210),
        ("Peri Peri Fries", "Snack", 1, 120),
        ("Farmhouse 10-inch Pizza", "Pizza", 1, 380),
        ("BBQ Chicken Wings", "Appetizer", 0, 270),
        ("Chocolate Milkshake", "Beverage", 1, 150)
    ],
    "Desserts": [
        ("Gulab Jamun (2 pcs)", "Mithai", 1, 90),
        ("Rasmalai (2 pcs)", "Mithai", 1, 120),
        ("Chocolate Truffle Pastry", "Bakery", 1, 140),
        ("Sizzling Brownie with Ice Cream", "Dessert", 1, 190),
        ("Kulfi Falooda", "Ice Cream", 1, 130)
    ]
}

VEHICLE_TYPES = ["Bike", "Scooter", "EV", "Bicycle"]
PAYMENT_METHODS = [
    {"payment_method_id": "PM_UPI", "method_name": "UPI / QR Code", "method_category": "UPI"},
    {"payment_method_id": "PM_CC", "method_name": "Credit Card", "method_category": "CARD"},
    {"payment_method_id": "PM_DC", "method_name": "Debit Card", "method_category": "CARD"},
    {"payment_method_id": "PM_NB", "method_name": "Net Banking", "method_category": "NETBANKING"},
    {"payment_method_id": "PM_COD", "method_name": "Cash on Delivery", "method_category": "COD"},
    {"payment_method_id": "PM_WALLET", "method_name": "Digital Wallet", "method_category": "WALLET"}
]

def generate_customers(count: int = 250) -> List[Dict[str, Any]]:
    """Generates synthetic Indian customer records with deliberate 2-3% dirty data."""
    customers = []
    base_date = datetime(2023, 1, 1)

    for i in range(1, count + 1):
        city_info = random.choice(INDIAN_CITIES)
        cust_id = f"CUST_{i:04d}"
        name = fake.name()
        email = f"{name.lower().replace(' ', '.')}.{i}@example.in"
        phone = f"+91-{random.randint(6000000000, 9999999999)}"
        signup_dt = (base_date + timedelta(days=random.randint(0, 365))).strftime("%Y-%m-%d")
        pincode = str(random.randint(110001, 700100))

        # Deliberate dirty data injection (~2.5%)
        if i % 40 == 0:
            # Dirty: untrimmed spaces or missing phone
            name = f"   {name}   "
            phone = ""
        elif i % 50 == 0:
            # Dirty: malformed pincode and uppercase email
            email = email.upper()
            pincode = "INVALID_PIN"

        customers.append({
            "customer_id": cust_id,
            "customer_name": name,
            "email": email,
            "phone": phone,
            "city": city_info["city"],
            "state": city_info["state"],
            "pincode": pincode,
            "signup_date": signup_dt
        })
    return customers

def generate_restaurants(count: int = 40) -> List[Dict[str, Any]]:
    """Generates synthetic restaurant partners with Indian cuisines and locations."""
    restaurants = []
    cuisine_list = list(CUISINE_MENUS.keys())

    for i in range(1, count + 1):
        city_info = random.choice(INDIAN_CITIES)
        rest_id = f"REST_{i:03d}"
        cuisine = random.choice(cuisine_list)
        area = random.choice(city_info["areas"])
        name = f"{fake.last_name()}'s {cuisine} Kitchen"
        rating = round(random.uniform(3.4, 4.9), 1)
        cost_for_two = random.choice([300, 450, 600, 800, 1100, 1500])
        is_active = 1 if random.random() > 0.08 else 0

        # Dirty data injection (~2.5%)
        if i % 30 == 0:
            # Dirty: negative cost for two
            cost_for_two = -150

        restaurants.append({
            "restaurant_id": rest_id,
            "name": name,
            "cuisine_type": cuisine,
            "city": city_info["city"],
            "area": area,
            "rating": rating,
            "cost_for_two": cost_for_two,
            "is_active_partner": is_active
        })
    return restaurants

def generate_menu_items(restaurants: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Generates menu catalogs linked to each restaurant based on their cuisine."""
    menu_items = []
    item_counter = 1

    for rest in restaurants:
        cuisine = rest["cuisine_type"]
        items_template = CUISINE_MENUS.get(cuisine, CUISINE_MENUS["North Indian"])
        
        for item_name, category, is_veg, base_price in items_template:
            # Price variation +/- 10%
            varied_price = round(base_price * random.uniform(0.9, 1.15), 2)
            menu_items.append({
                "item_id": f"ITEM_{item_counter:04d}",
                "restaurant_id": rest["restaurant_id"],
                "item_name": item_name,
                "category": category,
                "is_veg": is_veg,
                "base_price": varied_price,
                "is_available": 1 if random.random() > 0.05 else 0
            })
            item_counter += 1
            
    return menu_items

def generate_delivery_partners(count: int = 60) -> List[Dict[str, Any]]:
    """Generates delivery fleet riders across operating cities."""
    partners = []
    for i in range(1, count + 1):
        city_info = random.choice(INDIAN_CITIES)
        part_id = f"PART_{i:03d}"
        name = fake.name()
        phone = f"+91-{random.randint(6000000000, 9999999999)}"
        vehicle = random.choice(VEHICLE_TYPES)
        rating = round(random.uniform(3.7, 5.0), 1)
        status = random.choices(["ACTIVE", "ON_LEAVE", "INACTIVE"], weights=[0.85, 0.10, 0.05])[0]

        # Dirty data injection (~2.5%)
        if i % 35 == 0:
            rating = 6.5  # Out-of-bounds rating for DQ demonstration

        partners.append({
            "partner_id": part_id,
            "partner_name": name,
            "phone": phone,
            "vehicle_type": vehicle,
            "city": city_info["city"],
            "rating": rating,
            "status": status
        })
    return partners

def export_to_csv(data: List[Dict[str, Any]], filename: str, output_dir: Path = DATA_LANDING_DIR) -> Path:
    """Exports a list of dicts to a CSV file in the target directory."""
    filepath = output_dir / filename
    if not data:
        logger.warning(f"No data to write for {filename}")
        return filepath

    keys = data[0].keys()
    with open(filepath, mode="w", newline="", encoding="utf-8") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=keys)
        writer.writeheader()
        writer.writerows(data)

    logger.info(f"Wrote {len(data)} records to {filepath}")
    return filepath

def run_master_generation() -> Dict[str, Any]:
    """Generates all master files and writes them to the landing folder."""
    logger.info("Starting master data generation...")
    customers = generate_customers(count=250)
    restaurants = generate_restaurants(count=40)
    menu_items = generate_menu_items(restaurants)
    delivery_partners = generate_delivery_partners(count=60)

    export_to_csv(customers, "customers.csv")
    export_to_csv(restaurants, "restaurants.csv")
    export_to_csv(menu_items, "menu_items.csv")
    export_to_csv(delivery_partners, "delivery_partners.csv")
    export_to_csv(PAYMENT_METHODS, "payment_methods.csv")

    logger.info("Master data generation completed successfully!")
    return {
        "customers_count": len(customers),
        "restaurants_count": len(restaurants),
        "menu_items_count": len(menu_items),
        "delivery_partners_count": len(delivery_partners),
        "payment_methods_count": len(PAYMENT_METHODS)
    }

if __name__ == "__main__":
    run_master_generation()
