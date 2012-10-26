#! /usr/bin/perl


my $oolink = "http://www.openstreetmap.org/browse";
my $ojlink = "http://127.0.0.1:8111/import?url=http://www.openstreetmap.org/api/0.6";
my $jtext  = "**";

while (<>) {
    s/\n/<br>\n/g;
    s/; ERROR: //;
    s[(:r?)(\d\d+)][$1<a href="$oolink/way/$2">$2</a> <a href="$ojlink/way/$2/full">$jtext</a>]g;
    s[(\d+):(\d\D)][<a href="$oolink/way/$1">$1</a> <a href="$ojlink/way/$1/full">$jtext</a>:$2]g;
    s[NodeID=(\d+)][NodeID=<a href="$oolink/node/$1">$1</a> <a href="$ojlink/node/$1/full">$jtext</a>]gi;
    s[nodes (\d+)][nodes <a href="$oolink/node/$1">$1</a> <a href="$ojlink/node/$1/full">$jtext</a>]gi;
    s[ and (\d+)][ and <a href="$oolink/node/$1">$1</a> <a href="$ojlink/node/$1/full">$jtext</a>]gi;
    s[WayID=(\d+)][WayID=<a href="$oolink/way/$1">$1</a> <a href="$ojlink/way/$1/full">$jtext</a>]gi;
    s[Rel(?:ation)?ID=(\d+)][RelID=<a href="$oolink/relation/$1">$1</a> <a href="$ojlink/relation/$1/full">$jtext</a>]gi;
    s[\(([\d\-\.]+),([\d\-\.]+)\)][sprintf "(<a href='http://www.openstreetmap.org/?lat=$1&lon=$2&zoom=18'>$1,$2</a>) <a href='http://127.0.0.1:8111/load_and_zoom?left=%f&right=%f&top=%f&bottom=%f'>$jtext</a>", $2-0.0002, $2+0.0002, $1+0.0001, $1-0.0001]ge;
    print;
}