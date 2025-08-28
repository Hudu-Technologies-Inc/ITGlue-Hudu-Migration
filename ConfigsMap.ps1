# source 
$CONSTANTS=@(
    ## @{literal="constval";to_label="constfield"}
)
$SMOOSHLABELS=@(
    "Model Name","Location Name","Manufacturer Name",
    "Configuration Status Name","Asset Tag","Default Gateway","MAC Address",
"Purchased At","Purchased By","Primary IP",
"Installed At","Installed By",
    "Notes","Operating System Notes"
)
$mapping=@(
@{from='Operating System Name';to='Version'; dest_type='Text'; required='False'},
@{from='Hostname';to='Business Impact'; dest_type='RichText'; required='False'},
@{from='Contact Name';to='Application Champion'; dest_type='Text'; required='False'},
@{from='Model ID';to='Licensing & Support Information'; dest_type='Heading'; required='False'},
@{from='SMOOSH';to='Notes'; dest_type='RichText'; required='False'},
@{from='Warranty Expires At';to='New Computer/User setup'; dest_type='RichText'; required='False'})# if fields are blank, exclude during smoosh procress?
$includeblanksduringsmoosh = $false

# relate archived objects to new asset / object
$includeRelationsForArchived = $true

# set below to true if smooshing to plaintext field, otherwise leave for richtext field
# (strip html when going to text field)
$excludeHTMLinSMOOSH = $false

# include description of related objects in smoosh
# related objects will have a 1-line description based on related object type and name
$describeRelatedInSmoosh = $true

# include label - above value in smooshed? IE - 
# label -
# value
$includeLabelInSmooshedValues = $true
