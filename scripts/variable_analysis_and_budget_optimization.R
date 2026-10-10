#!/usr/bin/env Rscript
# ============================================================================
# E-commerce customer analytics  |  Data Diagnostics, Variable Analysis, and Budget Optimization (R)
# ============================================================================
# WHAT THIS DOES
#   A self-contained companion to the solution notebook. Running it prints, for
#   every variable, its distribution and details, then reproduces the notebook's
#   analyses as runnable checks (segments, value drivers, the age marginal vs
#   conditional decomposition, channel economics, category mix, retention cadence,
#   geography, lapsed win-back, and the formal hypothesis tests), and finally
#   solves the coupon budget as an integer linear program.
#
# HOW TO READ THE OUTPUT
#   Every result is followed by a plain-language "Reading it:" note, and the run
#   ends with a "Key takeaways" summary, so the output stands on its own.
#
# HOW TO RUN
#   Rscript variable_analysis_and_budget_optimization.R
#   (only base R plus the stats package are required; lpSolve installs on first run)
# ============================================================================

# lpSolve provides the integer/linear programming solver used in the budget part.
if (!requireNamespace("lpSolve", quietly = TRUE)) install.packages("lpSolve", repos = "https://cloud.r-project.org")
suppressMessages(library(lpSolve))
options(width = 105)  # wider console so wrapped "Reading it:" notes and tables stay aligned

# ---- tee the whole run to a report file under outputs/ (so the printed report is saved on disk) ----
out_dir <- if (dir.exists("data")) "outputs" else "../outputs"          # outputs/ sits beside the data/ folder
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)         # create it on first run if missing
report_path <- file.path(out_dir, "variable_analysis_and_budget_optimization.txt")  # the saved terminal report
report_con  <- file(report_path, open = "wt")                           # open the report file for writing
sink(report_con, split = TRUE)                                          # split = send every cat/print to console AND file

# ---- small helpers so every section prints in the same readable shape ----
rule <- function(title) {                                  # a titled banner that separates sections
  bar <- paste(rep("=", 78), collapse = "")
  cat("\n", bar, "\n", title, "\n", bar, "\n", sep = "")
}
sub_rule <- function(title) cat("\n---", title, "---\n")    # a lighter sub-header inside a section
reading <- function(...) {                                  # a wrapped, indented plain-language takeaway
  txt <- paste(...)                                         # space-separate args so sentence fragments never glue together
  txt <- gsub("[[:space:]]+", " ", txt)                    # collapse any whitespace runs to single spaces
  txt <- gsub(" ([.,;:)%])", "\\1", txt)                   # drop a space that landed before punctuation
  txt <- gsub("([($]) ", "\\1", txt)                       # drop a space right after an opening paren or dollar sign
  cat(strwrap(paste("Reading it:", txt), width = 100, exdent = 2), sep = "\n"); cat("\n")
}
money <- function(x) paste0("$", format(round(x), big.mark = ",", scientific = FALSE))  # dollar formatting
pct   <- function(x) sprintf("%.1f%%", 100 * x)             # percent formatting

# ---- load the four data tables ----
data_dir     <- if (dir.exists("data")) "data" else "../data"   # find the data folder from either location
customers    <- read.csv(file.path(data_dir, "customers.csv"),    stringsAsFactors = FALSE)  # one row per customer
transactions <- read.csv(file.path(data_dir, "transactions.csv"), stringsAsFactors = FALSE)  # one row per purchase
clv          <- read.csv(file.path(data_dir, "clv_targets.csv"),  stringsAsFactors = FALSE)  # value we predict (next 12 mo)
channels     <- read.csv(file.path(data_dir, "channels.csv"),     stringsAsFactors = FALSE)  # per-channel cost and commission
transactions$transaction_date <- as.Date(transactions$transaction_date)                      # text to real dates
V   <- "target_clv_next_12_months"                          # the target column name, reused throughout
REF <- as.Date("2026-07-01")                                # "as of today": the target measures spend from here on,
                                                            #   so all features below use only data up to 2026-06-30

# ---- build per-customer RFM features (Recency, Frequency, Monetary, average order value) ----
by_customer <- split(transactions, transactions$customer_id)          # group the purchase log by customer
rfm <- data.frame(
  customer_id = names(by_customer),                                   # customer id
  frequency   = sapply(by_customer, nrow),                            # number of purchases
  monetary    = sapply(by_customer, function(d) sum(d$amount)),       # total money spent
  aov         = sapply(by_customer, function(d) mean(d$amount)),      # average order value
  recency     = sapply(by_customer, function(d) as.numeric(REF - max(d$transaction_date))),  # days since last purchase
  stringsAsFactors = FALSE
)
feat <- merge(merge(customers, rfm, by = "customer_id"), clv, by = "customer_id")  # profile + behaviour + answer

# ---- reproduce the notebook's 3 segments with k-means (matches sklearn 148/380/472 to within one row) ----
# why this transform: log1p tames the right-skew in the money/count features so a few whales do not dominate the
#   Euclidean distance, and scale() standardizes every axis so none outweighs the others in the clustering.
Xseg <- scale(log1p(feat[, c("recency", "frequency", "monetary", "aov")]))
set.seed(42)                                                          # fix the random restarts for reproducibility
km   <- kmeans(Xseg, centers = 3, nstart = 25, iter.max = 50)         # k=3 (silhouette/elbow choice), 25 restarts
# name clusters by their median spend so labels are stable across runs: lowest -> Occasional, highest -> VIPs
med_mon <- tapply(feat$monetary, km$cluster, median)
seg_names <- setNames(c("Occasional Shoppers", "Bargain Hunters", "VIPs")[rank(med_mon)], names(med_mon))
feat$segment <- unname(seg_names[as.character(km$cluster)])
feat$segment <- factor(feat$segment, levels = c("VIPs", "Bargain Hunters", "Occasional Shoppers"))

# ---- age bands, reused by the age and hypothesis-test sections ----
feat$band <- cut(feat$age, breaks = c(17, 28, 38, 48, 58, 100),
                 labels = c("18-28", "29-38", "39-48", "49-58", "59+"))

cat(sprintf("Loaded: %d customers, %d transactions, %d channels. Segments: %d VIPs, %d Bargain, %d Occasional.\n",
            nrow(customers), nrow(transactions), nrow(channels),
            sum(feat$segment == "VIPs"), sum(feat$segment == "Bargain Hunters"), sum(feat$segment == "Occasional Shoppers")))


# ============================================================================
# ANALYSIS SECTION FUNCTIONS (each prints its own findings with a plain-language note)
# ============================================================================

section_overview <- function() {
  rule("DATA OVERVIEW: every variable, its distribution and details")

  # ---- NUMERIC variables: one summary row each ----
  sub_rule("Numeric variables: distribution and shape")
  num_vars <- c("age", "recency", "frequency", "monetary", "aov", V)   # the six numeric columns to profile
  labels   <- c("age", "recency", "frequency", "monetary", "aov", "target_clv")  # short display names, target is long
  # skewness helper: standardized third moment, positive means a long right tail
  skewness <- function(x) mean(((x - mean(x)) / sd(x))^3)
  # aligned header: fixed-width columns so the table reads cleanly in a mono console
  cat(sprintf("%-11s %5s %4s %9s %9s %9s %9s %9s %9s %9s %7s\n",
              "variable", "n", "miss", "min", "q1", "median", "mean", "q3", "max", "sd", "skew"))
  for (i in seq_along(num_vars)) {
    x  <- feat[[num_vars[i]]]                                # pull the column
    nm <- sum(is.na(x))                                      # count missing before dropping them
    x  <- x[!is.na(x)]                                       # drop NAs for the numeric summary
    qs <- quantile(x, c(0.25, 0.5, 0.75))                   # q1, median, q3 in one call
    cat(sprintf("%-11s %5d %4d %9.1f %9.1f %9.1f %9.1f %9.1f %9.1f %9.1f %7.2f\n",
                labels[i], length(x), nm, min(x), qs[1], qs[2], mean(x), qs[3], max(x), sd(x), skewness(x)))
  }
  reading("Age spans a wide range and is roughly flat (skew near zero), but monetary and target value are strongly ",
          "right skewed: their medians sit far below their maxima, so a small number of heavy spenders sit in a long right tail.")

  # ---- text histograms for the two most skewed variables ----
  # small helper: 10 equal-width bins, counts drawn as a bar of '#'
  txt_hist <- function(x, title) {
    x    <- x[!is.na(x)]                                     # guard against missing
    br   <- seq(min(x), max(x), length.out = 11)            # 10 bins need 11 edges
    cnt  <- hist(x, breaks = br, plot = FALSE)$counts        # counts per bin, no plotting device
    maxc <- max(cnt)                                         # scale bars to the fullest bin
    sub_rule(paste0("Histogram: ", title, " (10 equal-width bins)"))
    for (b in seq_along(cnt)) {
      bar <- paste(rep("#", round(40 * cnt[b] / maxc)), collapse = "")  # bar width up to 40 chars
      cat(sprintf("%9.0f to %9.0f | %5d %s\n", br[b], br[b + 1], cnt[b], bar))  # edges, count, bar
    }
  }
  txt_hist(feat$monetary, "monetary (total spend)")          # most skewed money variable
  txt_hist(feat[[V]],     "target_clv (next 12 months)")     # the value we predict, also right skewed
  reading("Both histograms pile up in the leftmost, lowest-value bins and thin out to the right: most customers are ",
          "low to mid value, and a thin tail of big spenders stretches the axis, which is the signature of a right skew.")

  # ---- CATEGORICAL variables: frequency tables sorted descending ----
  sub_rule("Categorical variables: frequency and share")
  # small helper: count + pct share, sorted from most to least common
  cat_table <- function(x, title) {
    tb <- sort(table(x), decreasing = TRUE)                  # counts high to low
    tot <- sum(tb)                                           # denominator for the share
    cat(sprintf("\n%s (n = %d)\n", title, tot))              # sub-title with the total
    for (lv in names(tb)) {
      cat(sprintf("  %-14s %6d  %7s\n", lv, tb[[lv]], pct(tb[[lv]] / tot)))  # label, count, share
    }
  }
  cat_table(feat$gender,              "gender (per customer)")               # demographic
  cat_table(feat$country,             "country (per customer)")              # geography
  cat_table(feat$acquisition_channel, "acquisition_channel (per customer)")  # how they arrived
  cat_table(transactions$category,    "category (per transaction row)")      # product mix by purchase count
  reading("Behaviour and value variables (monetary, target) are right skewed, so a few big spenders carry most of the ",
          "value, while demographics like age are spread evenly; the categorical splits show where volume sits by ",
          "country, channel, and product category.")
}

section_segments <- function() {
  rule("SEGMENTS: who they are and how value concentrates")

  # fixed row order so the small high-value tier reads first
  segs  <- c("VIPs", "Bargain Hunters", "Occasional Shoppers")
  n_all <- nrow(feat)                              # total customers (1000)
  gtv   <- sum(feat[[V]])                          # grand total of target value across all customers

  sub_rule("Per-segment profile (medians) and share of total value")
  # aligned header: one column per profile metric plus size, mix, and value share
  cat(sprintf("%-20s %5s %7s %8s %6s %10s %8s %5s %11s %8s\n",
              "segment", "n", "pct", "recency", "freq", "monetary", "aov", "age", "med_value", "val_shr"))

  for (s in segs) {                                # walk segments in the fixed order above
    idx <- feat$segment == s                       # boolean mask selecting this segment's rows
    n_s <- sum(idx)                                # segment size
    # medians describe the typical customer without letting a few whales distort the picture
    cat(sprintf("%-20s %5d %7s %8.0f %6.0f %10s %8s %5.0f %11s %8s\n",
                s,                                  # segment label
                n_s,                                # count
                pct(n_s / n_all),                   # share of all customers
                median(feat$recency[idx]),          # typical days since last purchase
                median(feat$frequency[idx]),        # typical number of purchases
                money(median(feat$monetary[idx])),  # typical total spend
                money(median(feat$aov[idx])),       # typical average order value
                median(feat$age[idx]),              # typical age (expected similar across segments)
                money(median(feat[[V]][idx])),      # typical next-12-month value
                pct(sum(feat[[V]][idx]) / gtv)))    # this segment's share of ALL predicted value
  }

  # pull the headline numbers back out for the plain-language takeaway
  vip_idx   <- feat$segment == "VIPs"
  vip_pct   <- sum(vip_idx) / n_all                        # VIP share of customers
  vip_share <- sum(feat[[V]][vip_idx]) / gtv               # VIP share of total value
  age_med   <- tapply(feat$age, feat$segment, median)      # median age per segment
  age_spread <- max(age_med) - min(age_med)                # spread in median age across segments

  reading("Value is concentrated: VIPs are ", pct(vip_pct), " of customers but hold ", pct(vip_share),
          " of predicted next-year value. Segments differ sharply on behaviour (frequency, recency, spend) yet ",
          "median age varies only ", round(age_spread), " years across them, so these are behavioural tiers, not ",
          "demographic ones. Target by behaviour, not by age or demographics.")
}

section_drivers <- function() {
  rule("VALUE DRIVERS: what predicts next-year value")  # big banner header

  y <- feat[[V]]                                            # the value we predict (next 12 month CLV)
  drivers <- c("recency", "frequency", "monetary", "aov", "age")  # candidate behaviours to test

  ## 1) Simple correlation of each behaviour with future value ------------------
  sub_rule("Correlation with next-year value (sorted by strength)")
  cors <- sapply(drivers, function(v) cor(feat[[v]], y))   # Pearson correlation of each driver vs target
  ord <- order(abs(cors), decreasing = TRUE)               # rank by absolute strength, strongest first
  cors <- cors[ord]                                        # reorder the named vector
  cat(sprintf("%-11s %8s\n", "driver", "corr"))            # aligned table header
  for (v in names(cors))                                   # walk drivers strongest to weakest
    cat(sprintf("%-11s %8.3f\n", v, cors[[v]]))            # fixed width name, 3 dp correlation
  reading("Every behaviour points the same way, but total spend (monetary) is far and away the",
          "strongest single predictor of what a customer is worth next year.")

  ## 2) Full linear model on all five behaviours -------------------------------
  sub_rule("Multiple regression: target ~ recency + frequency + monetary + aov + age")
  m <- lm(y ~ recency + frequency + monetary + aov + age, data = feat)  # fit all drivers jointly
  co <- summary(m)$coefficients                            # matrix: estimate, se, t, p per term
  cat(sprintf("%-12s %12s %10s\n", "term", "coef", "p_value"))  # aligned header
  for (r in rownames(co))                                  # print each coefficient row
    cat(sprintf("%-12s %12.4f %10.4g\n", r, co[r, "Estimate"], co[r, "Pr(>|t|)"]))  # coef and p
  cat(sprintf("R-squared: %.4f\n", summary(m)$r.squared))  # variance explained by the full model
  reading("Spend dominates. Frequency and average order value can turn NEGATIVE here even though each",
          "is positive on its own: because monetary equals frequency times average order value by",
          "construction, they are collinear, so their signs flip once spend is in the model. This is a",
          "statistical artefact, not a real negative effect. Age matters but is tiny, about $1.4 per year.")

  ## 3) Naive spend-only baseline ----------------------------------------------
  sub_rule("Naive baseline: target ~ monetary alone")
  m0 <- lm(y ~ monetary, data = feat)                      # single-predictor model on spend only
  cat(sprintf("R-squared (monetary only): %.4f\n", summary(m0)$r.squared))  # near-perfect fit
  reading("Spend alone already explains almost everything (R-squared about 0.998). Future value is",
          "driven by how much a customer has already spent, not by who they are.")

  invisible(NULL)                                          # section prints via side effects only
}

section_age <- function() {
  rule("AGE, THE FULL STORY: marginal vs conditional (the flagship test)")

  # Pull the vectors we reuse throughout, straight from feat (no reload).
  a   <- feat$age                     # customer age in years
  tgt <- feat[[V]]                    # target CLV next 12 months (the value we predict)
  mon <- feat$monetary                # total past spend
  ratio <- tgt / mon                  # value returned per $1 of past spend

  # ---- 1) THREE CORRELATIONS: marginal, spend-orthogonality, conditional ----
  sub_rule("1) Marginal vs conditional correlations")
  c_marg  <- cor(a, tgt)              # age vs value: the MARGINAL signal (tiny)
  c_spend <- cor(a, mon)             # age vs spend: near zero, so age is not a spend proxy
  c_cond  <- cor(a, ratio)          # age vs value-per-dollar: the CONDITIONAL signal (large)
  cat(sprintf("  cor(age, value)              MARGINAL   = % .3f\n", c_marg))
  cat(sprintf("  cor(age, spend)              spend-link = % .3f\n", c_spend))
  cat(sprintf("  cor(age, value-per-dollar)   CONDITIONAL= % .3f\n", c_cond))
  reading(
    "The marginal age-to-value link is tiny (", sprintf("%.3f", c_marg),
    ") yet the conditional link is large (", sprintf("%.3f", c_cond),
    "). The reason: age carries almost no spend information (age-to-spend is ",
    sprintf("%.3f", c_spend),
    "), so age is not redundant with spend and its signal only surfaces once you ",
    "hold spend fixed, that is, in the value-per-dollar ratio."
  )

  # ---- 2) INCREMENTAL R-SQUARED: does age add anything on top of spend? ----
  sub_rule("2) Incremental R-squared of adding age to the spend model")
  m1 <- lm(tgt ~ mon)                 # baseline: value from spend alone
  m2 <- lm(tgt ~ mon + a)             # add age as a second predictor
  r1 <- summary(m1)$r.squared         # R2 of spend-only model
  r2 <- summary(m2)$r.squared         # R2 of spend + age model
  age_coef <- coef(m2)[["a"]]         # dollars of value per extra year of age
  cat(sprintf("  R2  value ~ spend          = %.5f\n", r1))
  cat(sprintf("  R2  value ~ spend + age    = %.5f\n", r2))
  cat(sprintf("  incremental R2 from age    = %.5f\n", r2 - r1))
  cat(sprintf("  age coefficient            = $%.2f per year\n", age_coef))  # 2 decimals: the effect is ~$1.41, not $1
  reading(
    "Spend already explains", pct(r1),
    "of value. Adding age lifts that by only", sprintf("%.5f", r2 - r1),
    "of R2 (about", sprintf("$%.2f", age_coef),
    "per year of age). Statistically detectable, but practically negligible."
  )

  # ---- 3) VALUE PER $1 OF PAST SPEND, BY AGE BAND: a rising series ----
  sub_rule("3) Value returned per $1 of past spend, by age band")
  # Mean of the ratio within each age band, kept in the factor's own level order.
  by_band <- tapply(ratio, feat$band, mean)
  by_band <- by_band[levels(feat$band)]      # enforce 18-28 ... 59+ ordering
  for (b in names(by_band)) {
    cat(sprintf("  %-6s  $%.2f returned per $1 spent\n", b, by_band[[b]]))
  }
  reading(
    "The return per dollar rises steadily with age, from about $",
    sprintf("%.2f", by_band[[1]]), " for the youngest band to about $",
    sprintf("%.2f", by_band[[length(by_band)]]),
    " for the oldest. Older customers give back a little more per dollar they have already spent."
  )

  # ---- 4) WITHIN-SEGMENT AGE EFFECT: real for two, absent for VIPs ----
  sub_rule("4) Within-segment age effect (young age<=38 vs old age>=59)")
  cat(sprintf("  %-20s %8s %10s %10s %8s\n",
              "segment", "corr", "young", "old", "gap"))
  for (s in levels(feat$segment)) {
    idx <- feat$segment == s               # rows in this segment
    cc  <- cor(a[idx], tgt[idx])          # age-to-value correlation inside the segment
    y   <- mean(tgt[idx & a <= 38])       # mean value for young members
    o   <- mean(tgt[idx & a >= 59])       # mean value for old members
    cat(sprintf("  %-20s % 8.3f %10s %10s %8s\n",
                s, cc, money(y), money(o), money(o - y)))
  }
  reading(
    "The age tilt is real inside Bargain Hunters and Occasional Shoppers: older ",
    "members are worth more, a positive correlation and a positive old-minus-young gap. ",
    "For VIPs the correlation is essentially zero to negative and the gap flips negative, ",
    "so among top customers age gives no edge, if anything the younger VIPs are worth more."
  )

  # ---- 5) ANOVA: is total value different across age bands at all? ----
  sub_rule("5) ANOVA of value across age bands")
  fit <- aov(tgt ~ feat$band)                    # does mean value differ by band?
  pval <- summary(fit)[[1]][["Pr(>F)"]][1]       # extract the F-test p-value
  cat(sprintf("  aov(value ~ age band)  p-value = %.3f\n", pval))
  reading(
    "The p-value is ", sprintf("%.3f", pval),
    ", far above 0.05, so total value does not differ across age bands. ",
    "Once you look at the raw dollars per customer, age bands are flat."
  )

  # ---- SECTION TAKEAWAY ----
  reading(
    "Age is a WEAK second-order retention signal: among equal-spend mid and low ",
    "value customers, older ones return a little more per dollar, but it adds almost ",
    "nothing to the value model (+", sprintf("%.4f", r2 - r1),
    " R2) and it VANISHES for VIPs, and total value is flat across age bands ",
    "(ANOVA not significant, p=", sprintf("%.2f", pval),
    "). So age is NOT a targeting lever, at most a minor within-segment tiebreaker, ",
    "and never for VIPs."
  )
}

section_channels <- function() {
  rule("CHANNEL ECONOMICS: net value after commission and acquisition cost")  # big banner header

  # Per-customer revenue keyed by acquisition channel; use monetary as the revenue base.
  rev_by_ch <- tapply(feat$monetary, feat$acquisition_channel, sum)             # total revenue per channel
  n_by_ch   <- tapply(feat$monetary, feat$acquisition_channel, length)          # customers acquired per channel

  # Align the channels economics table (cost_per_signup, revenue_share_rate) to our channel names.
  chn  <- names(rev_by_ch)                                                       # channel names present in feat
  idx  <- match(chn, channels$channel_name)                                     # row in channels for each name
  rate <- channels$revenue_share_rate[idx]                                       # commission fraction WE PAY
  cost <- channels$cost_per_signup[idx]                                          # acquisition cost per signup

  rev  <- as.numeric(rev_by_ch)                                                  # revenue vector
  n    <- as.numeric(n_by_ch)                                                    # count vector
  commission <- rev * rate                                                       # dollars paid to the channel
  acq_cost   <- n * cost                                                         # dollars spent to acquire
  net        <- rev * (1 - rate) - acq_cost                                      # NET value kept by us

  ord <- order(net, decreasing = TRUE)                                          # sort channels by NET, best first

  sub_rule("Per-channel net value (sorted by NET)")
  # Fixed-width header so columns line up in the console.
  cat(sprintf("%-10s %5s %13s %13s %11s %13s %10s\n",
              "Channel", "n", "Revenue", "Commission", "AcqCost", "NET", "Net/cust"))
  for (i in ord) {                                                              # walk channels in NET order
    cat(sprintf("%-10s %5d %13s %13s %11s %13s %10s\n",
                chn[i], n[i],                                                    # name and customers
                money(rev[i]), money(commission[i]),                            # revenue and commission paid
                money(acq_cost[i]), money(net[i]),                              # acquisition cost and NET
                money(net[i] / n[i])))                                          # NET per acquired customer
  }

  total_rev  <- sum(rev)                                                        # whole-mix revenue
  total_net  <- sum(net)                                                        # whole-mix NET
  total_n    <- sum(n)                                                          # whole-mix customers
  ret_ratio  <- total_net / (sum(commission) + sum(acq_cost))                   # net return per dollar of spend

  sub_rule("Whole-mix totals")
  cat(sprintf("Customers acquired : %d\n", total_n))                            # total customers
  cat(sprintf("Total revenue      : %s\n", money(total_rev)))                   # total revenue
  cat(sprintf("Whole-mix NET      : %s\n", money(total_net)))                   # summed NET across channels
  cat(sprintf("Net per customer   : %s\n", money(total_net / total_n)))         # average NET per customer
  cat(sprintf("Return per $ spent : %s\n",                                      # simple return figure
              sprintf("%.2fx", total_net / (sum(commission) + sum(acq_cost)))))

  reading("The revenue_share_rate is a commission WE PAY the channel, so higher-rate channels keep less of each revenue dollar. The current mix is strongly net positive, and Google plus Organic carry most of the net value.")
}

section_category <- function() {
  rule("PRODUCT MIX: category price tiers and spend share")               # big banner header

  catg <- transactions$category                                           # per transaction category label (avoid shadowing cat())
  amt  <- transactions$amount                                             # per transaction spend amount

  tot_spend_all <- sum(amt)                                               # grand total spend across all categories

  avg_price <- tapply(amt, catg, mean)                                    # average amount per category (price tier)
  tot_spend <- tapply(amt, catg, sum)                                     # total spend per category
  n_buy     <- tapply(amt, catg, length)                                  # number of purchases per category

  ord  <- order(avg_price, decreasing = TRUE)                            # sort categories high to low by price tier
  cats <- names(avg_price)[ord]                                           # category names in sorted order

  sub_rule("Categories sorted by average price (high to low)")            # light section header

  # aligned header row with fixed widths
  cat(sprintf("%-12s %10s %14s %12s %9s\n",
              "Category", "AvgPrice", "TotalSpend", "Purchases", "Share"))

  for (c in cats) {                                                       # one aligned row per category
    cat(sprintf("%-12s %10s %14s %12d %9s\n",
                c,                                                        # category name
                money(avg_price[[c]]),                                    # average price (dollar formatted)
                money(tot_spend[[c]]),                                    # total spend (dollar formatted)
                as.integer(n_buy[[c]]),                                   # purchase count
                pct(tot_spend[[c]] / tot_spend_all)))                     # share of total spend
  }

  top_spend <- names(tot_spend)[which.max(tot_spend)]                     # category driving the most total spend
  top_share <- tot_spend[[top_spend]] / tot_spend_all                    # its share of the total

  cat(sprintf("\n%s drives the most total spend at %s (%s of all spend).\n",
              top_spend, money(tot_spend[[top_spend]]), pct(top_share)))  # note the top spend driver

  reading(                                                                # plain-language takeaway
    "There are two price tiers: premium (Electronics near $90, Home near $82) ",
    "and value (Fashion and Beauty near $41, high volume but low price), with ",
    "Sports in the middle near $59. Electronics leads on both price and total ",
    "spend (about 31% of the total), so it is the single most important category."
  )
}

section_retention <- function() {
  rule("RETENTION AND CADENCE: how often and how recently they buy")      # big banner header

  # Map each customer_id to its segment so transaction rows can be labelled by segment.
  seg_of <- feat$segment                                                  # segment factor, one per customer
  names(seg_of) <- feat$customer_id                                       # key it by customer_id for lookup

  # ---- 1) INTER-PURCHASE CADENCE: median gap in days, per customer then per segment ----
  # For each customer, sort their transactions by date and take day gaps between them.
  gap_by_cust <- tapply(seq_len(nrow(transactions)),                      # split row indices by customer
                        transactions$customer_id,
                        function(ix) {
                          d <- sort(transactions$transaction_date[ix])    # this customer's dates, ascending
                          if (length(d) < 2) return(NA_real_)             # need 2+ buys to have a gap
                          median(as.numeric(diff(d)))                     # median day gap between buys
                        })

  # Attach each customer's segment to their median gap, aligned by customer_id.
  cust_ids  <- names(gap_by_cust)                                         # customer ids in the tapply order
  cust_seg  <- seg_of[cust_ids]                                           # segment for each of those ids
  # Median of the per-customer gaps within each segment (drop customers with a single buy).
  gap_seg   <- tapply(as.numeric(gap_by_cust), cust_seg,
                      function(v) median(v, na.rm = TRUE))

  # ---- 2) RECENCY: median days since last purchase, per segment ----
  rec_seg <- tapply(feat$recency, feat$segment,                          # recency already sits in feat
                    function(v) median(v, na.rm = TRUE))

  # ---- PER-SEGMENT TABLE (kept in the factor's own level order) ----
  sub_rule("Median inter-purchase gap and median recency, by segment")
  segs <- levels(feat$segment)                                           # VIPs, Bargain Hunters, Occasional Shoppers
  cat(sprintf("%-20s %14s %14s\n", "Segment", "MedianGap", "MedianRecency"))  # aligned header
  for (s in segs) {                                                      # one row per segment
    cat(sprintf("%-20s %11.0f d %11.0f d\n",                            # gap and recency in whole days
                s, gap_seg[[s]], rec_seg[[s]]))
  }

  reading(
    "VIPs buy on a tight cycle (median gap about ", sprintf("%.0f", gap_seg[["VIPs"]]),
    " days) and are freshly active (recency about ", sprintf("%.0f", rec_seg[["VIPs"]]),
    " days). Occasional Shoppers have long gaps (about ",
    sprintf("%.0f", gap_seg[["Occasional Shoppers"]]),
    " days) and long silence (recency about ",
    sprintf("%.0f", rec_seg[["Occasional Shoppers"]]),
    " days), with Bargain Hunters in between. A useful churn-risk rule: once a ",
    "customer's silence passes roughly twice their segment's normal cadence, fire ",
    "a win-back trigger, because they are overdue relative to how that segment buys."
  )
}

section_geography <- function() {
  rule("GEOGRAPHY AND DEMOGRAPHICS: volume vs per-head value")

  # Target value we predict, pulled once straight from feat (no reload).
  tgt <- feat[[V]]                                  # target CLV next 12 months

  # ---- 1) BY COUNTRY: headcount, total value, value per customer ----
  sub_rule("1) By country: volume vs value per customer")
  n_ctry   <- tapply(tgt, feat$country, length)      # customers per country
  tot_ctry <- tapply(tgt, feat$country, sum)         # total target value per country
  vpc_ctry <- tot_ctry / n_ctry                      # value PER CUSTOMER per country
  ord      <- order(n_ctry, decreasing = TRUE)       # sort by headcount, biggest first
  cat(sprintf("  %-8s %8s %14s %14s\n",
              "country", "n", "total value", "value/cust"))
  for (c in names(n_ctry)[ord]) {
    cat(sprintf("  %-8s %8d %14s %14s\n",
                c, n_ctry[[c]], money(tot_ctry[[c]]), money(vpc_ctry[[c]])))
  }
  # Spread of per-customer value tells us whether country carries a value signal.
  vpc_lo <- min(vpc_ctry)                             # cheapest country per head
  vpc_hi <- max(vpc_ctry)                             # richest country per head
  reading(
    "The countries differ hugely in headcount (from ", min(n_ctry), " to ", max(n_ctry),
    " customers) but barely in value per customer: every country sits between ",
    money(vpc_lo), " and ", money(vpc_hi),
    " per head. Bigger countries matter through VOLUME of customers, not because ",
    "those customers are individually richer."
  )

  # ---- 2) BY GENDER: headcount and value per customer ----
  sub_rule("2) By gender: volume vs value per customer")
  n_gen   <- tapply(tgt, feat$gender, length)         # customers per gender
  tot_gen <- tapply(tgt, feat$gender, sum)            # total target value per gender
  vpc_gen <- tot_gen / n_gen                          # value PER CUSTOMER per gender
  gord    <- order(n_gen, decreasing = TRUE)          # biggest group first
  cat(sprintf("  %-10s %8s %14s %14s\n",
              "gender", "n", "total value", "value/cust"))
  for (g in names(n_gen)[gord]) {
    cat(sprintf("  %-10s %8d %14s %14s\n",
                g, n_gen[[g]], money(tot_gen[[g]]), money(vpc_gen[[g]])))
  }
  reading(
    "Gender is roughly balanced (", min(n_gen), " to ", max(n_gen),
    " customers per group) and value per customer moves only between ",
    money(min(vpc_gen)), " and ", money(max(vpc_gen)),
    ", so gender carries no meaningful value signal either."
  )

  # ---- SECTION TAKEAWAY ----
  reading(
    "Geography and gender are VOLUME stories, not value signals: per-customer value ",
    "barely moves across country (", money(vpc_lo), " to ", money(vpc_hi),
    ") or gender (", money(min(vpc_gen)), " to ", money(max(vpc_gen)),
    "). Do NOT target by geography or gender, target by behaviour."
  )
}

section_lapsed <- function() {
  rule("LAPSED CUSTOMERS: size and shape of the win-back opportunity")  # big banner header

  ## 1) Define the lapsed pool by recency ------------------------------------
  thr <- quantile(feat$recency, 0.90)             # 90th percentile of recency, the lapsed cutoff in days
  lap <- feat$recency >= thr                       # boolean mask: customers at or beyond the cutoff
  n_lap  <- sum(lap)                               # how many lapsed customers
  n_all  <- nrow(feat)                            # total customers (1000)
  gtv    <- sum(feat[[V]])                         # grand total of predicted next-year value
  lap_val <- sum(feat[[V]][lap])                  # predicted value held by the lapsed pool
  lap_shr <- lap_val / gtv                         # lapsed share of total value

  sub_rule("Lapsed pool size and value")
  cat(sprintf("Recency threshold (90th pct): %.0f days\n", thr))          # print the day cutoff
  cat(sprintf("Lapsed customers            : %d of %d (%s)\n",
              n_lap, n_all, pct(n_lap / n_all)))                          # count and share of base
  cat(sprintf("Their share of total value  : %s (%s of %s)\n",
              pct(lap_shr), money(lap_val), money(gtv)))                  # value share, dollars for context
  reading("The lapsed pool is small, about ", pct(n_lap / n_all), " of customers, and holds only ",
          pct(lap_shr), " of predicted next-year value.")

  ## 2) Segment breakdown of the lapsed pool ---------------------------------
  sub_rule("Segment breakdown of lapsed customers")
  segs <- c("VIPs", "Bargain Hunters", "Occasional Shoppers")            # fixed order, high value tier first
  cat(sprintf("%-20s %6s %8s\n", "segment", "n", "pct"))                  # aligned header
  for (s in segs) {                                                       # one row per segment
    n_s <- sum(lap & feat$segment == s)                                   # lapsed count in this segment
    cat(sprintf("%-20s %6d %8s\n", s, n_s,
                pct(if (n_lap > 0) n_s / n_lap else 0)))                  # share of the lapsed pool
  }
  dom <- names(which.max(table(feat$segment[lap])))                       # dominant lapsed segment
  reading("The lapsed pool sits almost entirely in the ", dom, " segment, and includes essentially no VIPs.")

  ## 3) Product-category skew of lapsed purchases ----------------------------
  sub_rule("Category skew: lapsed purchase share vs all customers (index, >1 = over-index)")
  lap_ids <- feat$customer_id[lap]                                        # customer ids in the lapsed pool
  tx_lap  <- transactions$category[transactions$customer_id %in% lap_ids] # categories of lapsed purchases
  sh_all  <- prop.table(table(transactions$category))                    # category share across all purchases
  sh_lap  <- prop.table(table(factor(tx_lap, levels = names(sh_all))))   # lapsed share on the same categories
  idx     <- as.numeric(sh_lap) / as.numeric(sh_all)                     # skew index: lapsed share / all share
  names(idx) <- names(sh_all)                                            # keep category labels
  ord <- order(idx, decreasing = TRUE)                                   # sort most over-indexed first

  cat(sprintf("%-12s %10s %10s %8s\n", "category", "lap_shr", "all_shr", "index"))  # aligned header
  for (c in names(idx)[ord])                                             # walk categories high skew to low
    cat(sprintf("%-12s %10s %10s %8.2f\n", c,
                pct(sh_lap[[c]]), pct(sh_all[[c]]), idx[[c]]))           # shares and skew index
  over <- names(idx)[ord][idx[ord] > 1]                                  # categories that over-index
  over_txt <- if (length(over) > 0) paste(over, collapse = ", ") else "none"  # readable list
  reading("Categories that over-index among lapsed buyers (index above 1): ", over_txt, ". ",
          "Overall the lapsed pool is small, low value, and almost entirely Occasional Shoppers, ",
          "so win-back is a modest roadmap item, not a headline.")

  invisible(NULL)                                                        # section prints via side effects only
}

section_tests <- function() {
  rule("HYPOTHESIS TESTS: are the patterns statistically real")             # big banner header

  # 1) ANOVA of CLV target across the three behavioural segments.
  sub_rule("1) ANOVA: target CLV ~ segment")                                # light header
  aov_seg  <- aov(feat[[V]] ~ feat$segment)                                 # one-way ANOVA, value by segment
  ssum_seg <- summary(aov_seg)[[1]]                                         # extract the ANOVA table
  F_seg    <- ssum_seg[["F value"]][1]                                      # F statistic (first row = factor)
  p_seg    <- ssum_seg[["Pr(>F)"]][1]                                       # p-value for the segment effect
  cat(sprintf("  F = %8.2f   p = %s\n", F_seg,                              # aligned stat line
              format.pval(p_seg, digits = 3, eps = 1e-16)))                 # tidy p-value formatting
  cat(sprintf("  verdict: %s\n",                                            # plain one-line verdict
              if (p_seg < 0.05) "segment value differences are REAL (significant)"
              else "no significant difference across segments"))
  reading("Segments separate on value with near-zero p: the VIP / Bargain / Occasional split is a real value signal, not noise.")

  # 2) ANOVA of CLV target across age bands.
  sub_rule("2) ANOVA: target CLV ~ age band")                              # light header
  aov_band  <- aov(feat[[V]] ~ feat$band)                                  # one-way ANOVA, value by age band
  ssum_band <- summary(aov_band)[[1]]                                      # ANOVA table
  F_band    <- ssum_band[["F value"]][1]                                   # F statistic
  p_band    <- ssum_band[["Pr(>F)"]][1]                                    # p-value for the band effect
  cat(sprintf("  F = %8.2f   p = %s\n", F_band,                            # aligned stat line
              format.pval(p_band, digits = 3, eps = 1e-16)))
  cat(sprintf("  verdict: %s\n",                                           # plain one-line verdict
              if (p_band < 0.05) "value differs by age band (significant)"
              else "NO significant difference by age band (not a lever)"))
  reading("Age bands do not separate on value (p well above 0.05): age is not a targeting lever.")

  # 3) Chi-square: product category mix (transactions) vs segment.
  sub_rule("3) Chi-square: product category x segment")                    # light header
  seg_by_cust <- feat$segment[match(transactions$customer_id,              # map each transaction to its buyer's segment
                                    feat$customer_id)]
  tab_cs      <- table(transactions$category, seg_by_cust)                 # contingency table category x segment
  chi_cs      <- chisq.test(tab_cs)                                        # chi-square test of independence
  cat(sprintf("  X-squared = %8.2f   df = %d   p = %s\n",                  # aligned stat line
              chi_cs$statistic, chi_cs$parameter,                          # statistic and degrees of freedom
              format.pval(chi_cs$p.value, digits = 3, eps = 1e-16)))
  cat(sprintf("  verdict: %s\n",                                           # plain one-line verdict
              if (chi_cs$p.value < 0.05) "segments buy DIFFERENT product mixes (significant)"
              else "no difference in product mix across segments"))
  reading("Category purchase mix differs by segment with near-zero p: segments really do shop differently.")

  # 4) Correlation test: age vs CLV target.
  sub_rule("4) cor.test: age vs target CLV")                               # light header
  ct <- cor.test(feat$age, feat[[V]])                                      # Pearson correlation test
  cat(sprintf("  r = %6.3f   t = %6.2f   df = %d   p = %s\n",              # aligned stat line
              ct$estimate, ct$statistic, ct$parameter,                     # r, t statistic, df
              format.pval(ct$p.value, digits = 3, eps = 1e-16)))
  cat(sprintf("  verdict: %s\n",                                           # plain one-line verdict
              if (ct$p.value < 0.05) "age-value correlation is distinguishable from zero"
              else "age-value correlation is NOT distinguishable from zero"))
  reading("Age barely correlates with value (r near 0.03) and the correlation is not distinguishable from zero.")

  # Section-level takeaway tying the four tests together.
  reading("Segments and product mix differ for real, but value does NOT differ by age band, confirming age is not a targeting lever.")
}

section_budget <- function() {
  rule("BUDGET OPTIMIZATION: best coupon per segment as an integer linear program")
  # WHY THIS APPROACH: choosing one coupon level per segment under a fixed budget is a discrete decision,
  #   so it is written as a mixed-integer linear program. lpSolve returns the global optimum over the 64
  #   combinations; a greedy best-coupon-per-segment rule can break the budget or miss the best trade.
  # HOW IT WORKS: build a net-value matrix (segment by coupon), maximise total net subject to exactly one
  #   coupon per segment and total coupon spend within budget, with 0/1 decision variables.
  segments   <- c("VIPs", "Bargain Hunters", "Occasional Shoppers")   # the three segments (scenario populations below)
  population <- c(150, 350, 500)                                      # segment sizes from the coupon scenario
  coupons    <- c(0, 5, 10, 20)                                       # the coupon options in dollars
  budget     <- 10000                                                 # the fixed budget
  # incremental revenue per customer at each coupon (rows = segments, cols = coupons), from the scenario's lift table
  inc <- rbind(c(0, 15, 35, 60),   # VIPs
               c(0, 12, 18, 22),   # Bargain Hunters
               c(0,  8, 22, 30))   # Occasional Shoppers

  # net for a whole segment = population * (incremental revenue - coupon cost); coupon cost = population * coupon
  net_matrix  <- population * (inc - matrix(coupons, nrow = 3, ncol = 4, byrow = TRUE))  # dollars gained
  cost_matrix <- population * matrix(coupons, nrow = 3, ncol = 4, byrow = TRUE)          # dollars spent
  objective   <- as.vector(t(net_matrix))                            # flatten row-major to match variable order

  one_per_segment <- matrix(0, nrow = 3, ncol = 12)                  # constraint 1: exactly one coupon per segment
  for (i in 1:3) one_per_segment[i, ((i - 1) * 4 + 1):(i * 4)] <- 1
  budget_row  <- as.vector(t(cost_matrix))                           # constraint 2: total spend within budget
  constraints <- rbind(one_per_segment, budget_row)
  direction   <- c(rep("==", 3), "<=")
  rhs         <- c(rep(1, 3), budget)

  solution <- lp("max", objective, constraints, direction, rhs, all.bin = TRUE)  # maximise net, 0/1 variables
  choice   <- matrix(solution$solution, nrow = 3, byrow = TRUE)      # reshape 0/1 answers to segment by coupon
  chosen   <- coupons[apply(choice, 1, which.max)]                   # chosen coupon per segment
  spend    <- sum(population * chosen)                               # total coupon spend of the chosen plan

  sub_rule("Optimal coupon plan")
  for (i in 1:3) cat(sprintf("  %-20s coupon $%2d   (spend %s, net %s)\n", segments[i], chosen[i],
                             money(population[i] * chosen[i]),
                             money(population[i] * (inc[i, match(chosen[i], coupons)] - chosen[i]))))
  cat(sprintf("  Total net incremental revenue: %s  |  spend %s of the %s budget\n",
              money(solution$objval), money(spend), money(budget)))

  # compare against the "ignore the budget" greedy plan to show why the budget forces a compromise
  greedy_coupon <- coupons[apply(net_matrix, 1, which.max)]          # best coupon per segment on its own
  greedy_cost   <- sum(population * greedy_coupon)
  greedy_net    <- sum(sapply(1:3, function(i) net_matrix[i, match(greedy_coupon[i], coupons)]))
  reading(sprintf("every $1 of coupon returns about $%.2f of incremental revenue, and %s of the budget is left unspent. ",
                  (solution$objval + spend) / spend, money(budget - spend)),
          if (greedy_cost > budget)
            sprintf("The budget binds: giving every segment its own best coupon would cost %s and earn %s, so we trim the segment whose extra coupon dollars add least, giving up only %s of net.",
                    money(greedy_cost), money(greedy_net), money(greedy_net - solution$objval)) else "")
  invisible(list(chosen = chosen, net = solution$objval, spend = spend))
}

section_takeaways <- function(plan) {
  rule("KEY TAKEAWAYS: one-look summary of everything above")
  naive_r2 <- summary(lm(as.formula(paste(V, "~ monetary")), data = feat))$r.squared  # spend-only predictability
  mon_cor  <- cor(feat$monetary, feat[[V]])                                            # spend to value link
  age_cor  <- cor(feat$age, feat[[V]])                                                 # age to value link (marginal)
  vip_share <- sum(feat[[V]][feat$segment == "VIPs"]) / sum(feat[[V]])                 # VIP share of total value
  # whole-mix channel net, recomputed so the summary is self-contained
  net_by_ch <- sapply(seq_len(nrow(channels)), function(k) {
    sub <- feat[feat$acquisition_channel == channels$channel_name[k], ]
    sum(sub$monetary) * (1 - channels$revenue_share_rate[k]) - nrow(sub) * channels$cost_per_signup[k]
  })
  cat(sprintf("  1. Value is concentrated: %d VIPs (%s of customers) hold %s of next-year value.\n",
              sum(feat$segment == "VIPs"), pct(mean(feat$segment == "VIPs")), pct(vip_share)))
  cat(sprintf("  2. Value is driven by behaviour, not demographics: spend correlates %.3f with value and alone predicts %s of it;\n",
              mon_cor, pct(naive_r2)))
  cat(sprintf("     age correlates only %.3f and is a weak within-segment retention tiebreaker that does not apply to VIPs.\n", age_cor))
  cat(sprintf("  3. The acquisition mix is net positive overall: about %s after commission and signup cost.\n", money(sum(net_by_ch))))
  cat(sprintf("  4. Best coupon plan: VIPs $%d, Bargain Hunters $%d, Occasional Shoppers $%d, returning %s net for %s spent.\n",
              plan$chosen[1], plan$chosen[2], plan$chosen[3], money(plan$net), money(plan$spend)))
  invisible(NULL)
}

# ============================================================================
# RUN EVERYTHING (call each section in order; every section prints a "Reading it:" note)
# ============================================================================
section_overview()
section_segments()
section_drivers()
section_age()
section_channels()
section_category()
section_retention()
section_geography()
section_lapsed()
section_tests()
plan <- section_budget()
section_takeaways(plan)

# stop teeing and report where the saved copy landed (this final line prints to the console only)
sink()
close(report_con)
cat(sprintf("\nFull report also saved to %s\n", report_path))

