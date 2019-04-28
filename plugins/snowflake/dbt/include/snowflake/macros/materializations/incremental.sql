
{% materialization incremental, adapter='snowflake' -%}

  {%- set unique_key = config.get('unique_key') -%}
  {%- set full_refresh_mode = (flags.FULL_REFRESH == True) -%}
  {%- set identifier = model['alias'] -%}

  {%- set old_relation = adapter.get_relation(database=database, schema=schema, identifier=identifier) -%}
  {%- set target_relation = api.Relation.create(database=database, identifier=identifier, schema=schema, type='table') -%}
  {%- set exists_as_table = (old_relation is not none and old_relation.is_table) -%}
  {%- set exists_not_as_table = (old_relation is not none and not old_relation.is_table) -%}
  {%- set force_create = full_refresh_mode -%}

  -- setup

  {% set source_sql -%}
     {# wrap sql in parens to make it a subquery #}
     (
       {{ sql }}
    )
  {%- endset -%}

  {{ run_hooks(pre_hooks, inside_transaction=False) }}

  -- `BEGIN` happens here:
  {{ run_hooks(pre_hooks, inside_transaction=True) }}

  -- build model
  {% if force_create or old_relation is none -%}
    {%- call statement('main') -%}
      {# -- create or replace logic because we're in a full refresh or table is non existant. #}
      {% if old_relation is not none and old_relation.type == 'view' %}
          {{ log("Dropping relation " ~ old_relation ~ " because it is a view and this model is a table.") }}
          {{ adapter.drop_relation(old_relation) }}
      {% endif %}
      {# -- now create (or replace) the table because we're in full-refresh #}
      {{create_table_as(false, target_relation, source_sql)}}
    {%- endcall -%}
  
  {%- else -%}
    {# -- here is the incremental part #}
    {% set dest_columns = adapter.get_columns_in_relation(target_relation) %}
    {% set dest_cols_csv = dest_columns | map(attribute='quoted') | join(', ') %}
    {%- call statement('main') -%}
      {%- if unique_key is none -%}
        {# -- if no unique_key is provided run regular insert as Snowflake may complain #}
        insert into {{ target_relation }} ({{ dest_cols_csv }})
        (
          select {{ dest_cols_csv }}
          from {{ source_sql }}
        );
      {%- else -%}
        {# -- use merge if a unique key is provided #}
        {{ get_merge_sql(target_relation, source_sql, unique_key, dest_columns) }}
      {%- endif -%}
    {% endcall %}
  {%- endif %}

  {{ run_hooks(post_hooks, inside_transaction=True) }}

  -- `COMMIT` happens here
  {{ adapter.commit() }}

  {{ run_hooks(post_hooks, inside_transaction=False) }}

{%- endmaterialization %}