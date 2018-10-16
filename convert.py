import os.path
import sys
import glob
import csv
import yaml
import json
import galleon
import jsonschema
import xmltodict
import requests
from deepmerge import always_merger as merge
from functools import reduce


tag_placeholer = '__tag__'
value_placeholder = 'value'
schema = jsonschema.RefResolver.from_schema(
    requests.get('http://standard.open-contracting.org/1.1/en/release-schema.json').json()
)


def replace_dot_with_mapping(row, value, transforms=[]):

    first, *parts = reversed(row.split('.'))
    root = {
        "mapping": {
            first: {
                "src": value.replace("@", tag_placeholer),
            }
        }
    }
    if transforms:
        root['mapping'][first]['transforms'] = [
            {"name": tr} for tr in transforms
        ]
    scope = [root]
    for key in parts:
        scope.append({"mapping": {key: scope.pop()}})
    return scope[0]
            

def replace_slash_with_dot(row):
    return (row.lstrip("/")
            .replace('/', '.')
            .replace("@", tag_placeholer))


def convert(mapping_file):
    mappings = []
    sources = []
    name, _ = os.path.splitext(os.path.basename(mapping_file))
    with open(mapping_file) as fd:
        reader = csv.DictReader(fd)
        
        if not 'jsonpath' in reader.fieldnames:
            return
        for row in reader:
            if row.get('jsonpath'):
                mappings.append(
                    replace_dot_with_mapping(
                        row['jsonpath'].strip(),
                        replace_slash_with_dot(row['xpath'].strip()),
                        row['transforms'].strip().split(',') if row.get('transforms') else ''
                    )
                )
    if mappings:
        mapping = reduce(merge.merge, mappings, {})
        with open(os.path.join("galleon", '{}.yml'.format(name)), 'w') as out:
            yaml.dump(mapping, out)
        return True


def transform():
    for file in glob.glob("output/mapping/F*.csv"):
        if not convert(file):
            continue
        name, _ = os.path.splitext(os.path.basename(file))
        with open(os.path.join("galleon", f"{name}.yml")) as fd:
            mapper = galleon.Mapper(
                yaml.load(fd),
                schema
            )
            file = os.path.join('output', 'samples', f"{name}.xml")

            with open(file) as fd:
                base = os.path.basename(file)
                key, _ = os.path.splitext(base)
                path = os.path.join('output/ocds', "{}.json".format(key))
                with open(path, 'w') as df:

                    input = xmltodict.parse(
                        fd.read(),
                        attr_prefix=tag_placeholer,
                        cdata_key=value_placeholder,
                        dict_constructor=dict,
                    )
                    json.dump(
                        mapper.apply(input.get(key)),
                        df
                    )


if __name__ == '__main__':
    transform()
