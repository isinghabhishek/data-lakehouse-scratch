# Data Lakehouse from Scratch — Makefile
# Orchestrates Docker Compose services, dbt transformations, ingestion, demos, and tests.

-include .env

.DEFAULT_GOAL := help

.PHONY: help up down reset status ingest run-silver run-gold test bench \
        download-data demo-acid demo-time-travel demo-schema-evolution \
        demo-branching pytest

## help: Print available targets with descriptions (default)
help:
	@echo ""
	@echo "Data Lakehouse from Scratch — available targets:"
	@echo ""
	@echo "  Infrastructure:"
	@echo "    up                  Start all Docker Compose services in detached mode"
	@echo "    down                Stop all Docker Compose services"
	@echo "    reset               Destroy all data volumes and restart services (WARNING: data loss)"
	@echo "    status              Show service health and port bindings"
	@echo ""
	@echo "  Data Pipeline:"
	@echo "    download-data       Download sample NYC Yellow Taxi CSV into data/raw/"
	@echo "    ingest              Run Bronze ingestion script (pass ARGS=... for extra flags)"
	@echo "    run-silver          Run dbt Silver transformation models"
	@echo "    run-gold            Run dbt Gold aggregation models"
	@echo "    test                Run dbt data quality tests"
	@echo ""
	@echo "  Demos:"
	@echo "    demo-acid           Demonstrate ACID concurrent write correctness"
	@echo "    demo-time-travel    Demonstrate Iceberg time travel (snapshot queries)"
	@echo "    demo-schema-evolution  Demonstrate schema evolution (add/rename/drop column)"
	@echo "    demo-branching      Demonstrate Nessie catalog branching and merge"
	@echo ""
	@echo "  Benchmarks & Tests:"
	@echo "    bench               Run SQL benchmark queries and write benchmark_results.md"
	@echo "    pytest              Run property-based test suite with pytest + Hypothesis"
	@echo ""

## up: Start all Docker Compose services in detached mode
up:
	@echo "Starting lakehouse services..."
	docker compose up -d
	@echo "Services are starting. Run 'make status' to check health."

## down: Stop all Docker Compose services
down:
	docker compose down

## reset: Destroy all data volumes and restart services (WARNING: destroys all data)
reset:
	@echo "WARNING: This will destroy all data volumes and restart from scratch."
	docker compose down -v
	docker compose up -d
	@echo "Services restarted with clean volumes. Run 'make status' to check health."

## status: Show service health and port bindings
status:
	docker compose ps

## download-data: Download sample NYC Yellow Taxi CSV into data/raw/
download-data:
	bash scripts/download_sample_data.sh

## ingest: Run Bronze ingestion script (pass ARGS=... for extra CLI flags)
ingest:
	python scripts/ingest_bronze.py $(ARGS)

## run-silver: Run dbt Silver transformation models
run-silver:
	cd dbt && dbt run --select silver

## run-gold: Run dbt Gold aggregation models
run-gold:
	cd dbt && dbt run --select gold

## test: Run dbt data quality tests
test:
	cd dbt && dbt test

## bench: Run SQL benchmark queries and write benchmark_results.md
bench:
	bash scripts/benchmark.sh

## demo-acid: Demonstrate ACID concurrent write correctness
demo-acid:
	bash scripts/demo_acid.sh

## demo-time-travel: Demonstrate Iceberg time travel (snapshot queries)
demo-time-travel:
	bash scripts/demo_time_travel.sh

## demo-schema-evolution: Demonstrate schema evolution (add/rename/drop column)
demo-schema-evolution:
	bash scripts/demo_schema_evolution.sh

## demo-branching: Demonstrate Nessie catalog branching and merge
demo-branching:
	bash scripts/demo_branching.sh

## pytest: Run property-based test suite with pytest + Hypothesis
pytest:
	pytest tests/ --tb=short -v
