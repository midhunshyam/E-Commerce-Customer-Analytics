#!/usr/bin/env python3
"""
Shared feature engineering for the customer-analytics pipeline.

Turns the raw customers + transactions tables into one row per customer with RFM
and behavioural features. Imported by customer_segmentation.py, clv_regression.py
and score_customers.py so the feature definitions live in exactly one place.
"""
import os
import numpy as np, pandas as pd

RFM_DRIVERS = ["recency", "frequency", "monetary", "aov"]        # the four behaviours the segmentation clusters on
CATEGORICAL = ["gender", "country", "acquisition_channel"]       # demographic columns the CLV model one-hot encodes

def load_tables(data_dir):
    """Read the raw tables from a data folder. clv_targets is optional (absent for brand-new customers)."""
    customers = pd.read_csv(os.path.join(data_dir, "customers.csv"))
    transactions = pd.read_csv(os.path.join(data_dir, "transactions.csv"))
    customers["signup_date"] = pd.to_datetime(customers["signup_date"])                # text -> real dates
    transactions["transaction_date"] = pd.to_datetime(transactions["transaction_date"])
    clv_path = os.path.join(data_dir, "clv_targets.csv")
    clv_targets = pd.read_csv(clv_path) if os.path.exists(clv_path) else None           # only present for training
    return customers, transactions, clv_targets

def build_customer_features(customers, transactions):
    """
    One row per customer. The 'as of' date is the day after the latest purchase in the
    data, so recency and tenure are measured from the moment the history ends. On the
    training data that is 2026-07-01 (the day the target window opens), which keeps the
    features leak-safe; on new data it adapts automatically.
    """
    ref = transactions["transaction_date"].max() + pd.Timedelta(days=1)                 # "as of today" date
    agg = transactions.groupby("customer_id").agg(
        frequency=("transaction_id", "size"), monetary=("amount", "sum"), aov=("amount", "mean"),
        first=("transaction_date", "min"), last=("transaction_date", "max"), category_diversity=("category", "nunique"))
    agg["recency"] = (ref - agg["last"]).dt.days                                        # days since last purchase
    agg["active_span"] = (agg["last"] - agg["first"]).dt.days                           # days between first and last purchase
    shares = transactions.pivot_table(index="customer_id", columns="category", values="amount", aggfunc="sum", fill_value=0)
    shares = shares.div(shares.sum(1), axis=0)                                          # each category's share of the customer's spend
    shares.columns = [f"pct_{c.lower()}" for c in shares.columns]
    cust = customers.assign(tenure=(ref - customers["signup_date"]).dt.days)            # days since signup
    return cust.merge(agg.drop(columns=["first", "last"]), on="customer_id").merge(shares, on="customer_id")
