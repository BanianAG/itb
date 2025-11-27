import json.tool
from fastapi import APIRouter
from jinja2 import Environment, FileSystemLoader
import json
import os

router = APIRouter()

# Set up Jinja2 environment
env = Environment(loader=FileSystemLoader('packages/template_engine/templates'), block_start_string='{=',block_end_string='=}',variable_start_string='{@', variable_end_string='@}')

# Layer 1: Controller Function
def generate_template(template_name, data, id):
    """
    Generates a template based on the user's request.
    
    :param template_name: Name of the Jinja2 template to render (e.g., 'demo.sql.j2')
    :param data: The data from the repo.json file
    :return: The rendered output as a string
    """
    # Layer 2: Load the requested template
    try:
        template = env.get_template(template_name)
    except Exception as e:
        return f"Template {template_name} not found: {e}"

    # Layer 3: Render the template with the provided data
    try:
        if 'config' not in data:
            data['config'] = {}
        output = template.render(entities=data['entity'], attributes=data['attribute'], relations=data['relation'],attribute_types=data['attribute_type'],relation_types=data['relation_type'], config=data['config'], id=id)
    except Exception as e:
        return f"Error rendering template: {e}"

    return output

def save_file(template_to_generate, data, ent, path=None, name=None):
    output = generate_template(template_to_generate, data, ent["id"])

    if name:
        ent_name = name
    else:
        ent_name = ent["name"]

    # Write the output to a file
    if path:
        filename = f'{path}/{ent_name}'
    else:
         filename = f'{os.environ["API_TEMPLATE_OUTPUT_PATH"]}/{ent["group_path"]}{ent_name}'

    #Check for Filetyp suffix
    if filename.find('.') == -1:
        filename = filename+'.sql'

    os.makedirs(os.path.dirname(filename), exist_ok=True)
    with open(filename, 'w') as f:
        f.write(output)

    print(f"SQL file for {ent_name} with Template: {template_to_generate} generated successfully.")
    
    return True

@router.post("/generateAll")
async def generateAll(json_input: dict | None = None, repo_filepath: str | None = None, generate_tag: str | None = None):

    if not json_input:
        if not repo_filepath:
            repo_filepath = f'{os.environ["API_JSON_OUTPUT_PATH"]}/_master/{os.environ["API_JSON_FILENAME"]}'
            print("PATH: "+repo_filepath)
        with open(repo_filepath) as f:
            data = json.load(f)
    else:
        data = json_input

    for ent in data["entity"]:
        template_to_generate = 'demo.jinja2'
        save_file(template_to_generate, data, ent)

    return True